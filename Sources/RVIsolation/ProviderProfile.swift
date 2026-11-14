import Foundation
import RVDomain
import RVPolicy

/// A named, reviewed recipe for one service's gateway secret: where the
/// value may be sent, which methods and paths it may be used for, and the
/// variables a client reads. `rv secrets set NAME --provider ID` expands a
/// profile into a gateway delivery. Nothing here grants network access or
/// reads a value. Not to be confused with a secret *source* provider
/// (Keychain, 1Password, ...), which is where a value is read from.
public struct ProviderProfile: Sendable, Equatable {
    /// One upstream a credential of this profile may be bound to, with the
    /// rules any binding to it starts from. Empty `allow` allows any method
    /// and path, as an unscoped gateway binding does.
    public struct Endpoint: Sendable, Equatable {
        public let name: String
        public let upstream: URL
        public let surfaces: Set<GatewaySurface>
        public let allow: [GatewayAllowance]

        public init(name: String, upstream: URL, surfaces: Set<GatewaySurface>, allow: [GatewayAllowance]) {
            self.name = name
            self.upstream = upstream
            self.surfaces = surfaces
            self.allow = allow
        }
    }

    /// A variable a client reads its key from, and the one rv points at the gateway.
    public struct Credential: Sendable, Equatable {
        public let variable: String
        public let baseURLEnv: String
        public let placeholderPrefix: String
        /// The `Endpoint.name` this variable is bound to by default.
        public let endpoint: String

        public init(variable: String, baseURLEnv: String, placeholderPrefix: String, endpoint: String) {
            self.variable = variable
            self.baseURLEnv = baseURLEnv
            self.placeholderPrefix = placeholderPrefix
            self.endpoint = endpoint
        }
    }

    public let id: String
    public let displayName: String
    public let description: String
    public let endpoints: [Endpoint]
    public let credentials: [Credential]
    /// Binaries that may spend a value bound from this profile. Nil leaves it unpinned.
    public let binaries: [String]?
    public let notes: [String]

    public func endpoint(named name: String) -> Endpoint? {
        endpoints.first { $0.name == name }
    }
}

public enum ProviderCatalogError: Error, Sendable, Equatable {
    case invalid(String)

    public var message: String {
        switch self {
        case .invalid(let reason): "the provider catalog is invalid: \(reason)"
        }
    }
}

/// The profiles rv ships, decoded from `Resources/providers/providers.json`
/// with the same strictness as `secrets.json`: unknown keys, bad globs, a
/// non-https upstream, or two profiles claiming one id or variable refuse
/// the whole catalog. A refused catalog offers no profile and no default.
public struct ProviderCatalog: Sendable, Equatable {
    public static let maximumProfiles = 64
    static let maximumEndpoints = 8
    static let maximumCredentials = 8
    static let maximumNotes = 8

    public let profiles: [ProviderProfile]

    /// The embedded catalog, decoded once.
    public static let shipped: Result<ProviderCatalog, ProviderCatalogError> =
        decode(Data(PackageResources.providers_json))

    public func profile(id: String) -> ProviderProfile? {
        profiles.first { $0.id == id }
    }

    /// The profile credential that claims `variable`, with its endpoint. Validation keeps it unique.
    public func credential(
        for variable: String
    ) -> (profile: ProviderProfile, credential: ProviderProfile.Credential, endpoint: ProviderProfile.Endpoint)? {
        for profile in profiles {
            guard let credential = profile.credentials.first(where: { $0.variable == variable }),
                let endpoint = profile.endpoint(named: credential.endpoint)
            else { continue }
            return (profile, credential, endpoint)
        }
        return nil
    }

    public static func decode(_ data: Data) -> Result<ProviderCatalog, ProviderCatalogError> {
        let parsed: JSONSpellingValue
        do {
            parsed = try JSONSpellingParser.parse(data, maximumDepth: 16)
        } catch .duplicateKey(let key) {
            return .failure(.invalid("duplicate key \(DisplayedText.field(key))"))
        } catch {
            return .failure(.invalid("not a JSON object"))
        }
        guard let root = parsed.object else { return .failure(.invalid("not a JSON object")) }
        do {
            try SecretsDecoding.onlyKeys(root, ["version", "providers"], at: "document")
            guard case .number("1")? = root["version"] else { throw SecretsDecoding.Failure("version must be 1") }
            guard case .array(let entries)? = root["providers"], (1...maximumProfiles).contains(entries.count) else {
                throw SecretsDecoding.Failure("providers must list 1 to \(maximumProfiles) profiles")
            }
            var profiles: [ProviderProfile] = []
            var claims: [String: String] = [:]
            for (index, entry) in entries.enumerated() {
                let profile = try ProviderDecoding.profile(entry, index: index)
                guard profiles.contains(where: { $0.id == profile.id }) == false else {
                    throw SecretsDecoding.Failure("duplicate provider id \(profile.id)")
                }
                for credential in profile.credentials {
                    if let owner = claims[credential.variable] {
                        throw SecretsDecoding.Failure(
                            "\(credential.variable) is claimed by more than one profile (\(owner), \(profile.id))")
                    }
                    claims[credential.variable] = profile.id
                }
                profiles.append(profile)
            }
            return .success(ProviderCatalog(profiles: profiles))
        } catch let failure as SecretsDecoding.Failure {
            return .failure(.invalid(failure.reason))
        } catch {
            return .failure(.invalid("unreadable entry"))
        }
    }
}

enum ProviderDecoding {
    typealias Failure = SecretsDecoding.Failure

    /// Lower-case letters and digits with inner `-`, so `id:endpoint` splits once.
    static func identifier(_ text: String) -> Bool {
        (1...32).contains(text.utf8.count) && text.hasPrefix("-") == false && text.hasSuffix("-") == false
            && text.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    static func profile(_ value: JSONSpellingValue, index: Int) throws -> ProviderProfile {
        let place = "providers[\(index)]"
        guard let object = value.object else { throw Failure("\(place) must be an object") }
        try SecretsDecoding.onlyKeys(
            object, ["id", "displayName", "description", "endpoints", "credentials", "binaries", "notes"], at: place)
        guard case .string(let id)? = object["id"], identifier(id) else {
            throw Failure("\(place).id must be 1 to 32 lower-case letters, digits or inner -")
        }
        let displayName = try text(object["displayName"], max: 64, at: "\(id).displayName")
        let description = try text(object["description"], max: 256, at: "\(id).description")
        guard case .array(let rawEndpoints)? = object["endpoints"], (1...ProviderCatalog.maximumEndpoints).contains(rawEndpoints.count)
        else { throw Failure("\(id).endpoints must list 1 to \(ProviderCatalog.maximumEndpoints) endpoints") }
        var endpoints: [ProviderProfile.Endpoint] = []
        for (offset, raw) in rawEndpoints.enumerated() {
            let endpoint = try self.endpoint(raw, at: "\(id).endpoints[\(offset)]")
            guard endpoints.contains(where: { $0.name == endpoint.name }) == false else {
                throw Failure("\(id).endpoints has \(endpoint.name) twice")
            }
            endpoints.append(endpoint)
        }
        var credentials: [ProviderProfile.Credential] = []
        if let raw = object["credentials"] {
            guard case .array(let list) = raw, list.count <= ProviderCatalog.maximumCredentials else {
                throw Failure("\(id).credentials must list up to \(ProviderCatalog.maximumCredentials) credentials")
            }
            for (offset, entry) in list.enumerated() {
                let place = "\(id).credentials[\(offset)]"
                let credential = try self.credential(entry, at: place)
                guard endpoints.contains(where: { $0.name == credential.endpoint }) else {
                    throw Failure("\(place).endpoint \(DisplayedText.field(credential.endpoint)) is not one of this profile's endpoints")
                }
                guard credentials.contains(where: { $0.variable == credential.variable }) == false else {
                    throw Failure("\(id).credentials has \(credential.variable) twice")
                }
                credentials.append(credential)
            }
        }
        var binaries: [String]?
        if let raw = object["binaries"] {
            guard let list = strings(raw), (1...16).contains(list.count), list.allSatisfy(SecretsDecoding.binaryPath),
                Set(list).count == list.count
            else { throw Failure("\(id).binaries must be 1 to 16 distinct absolute paths") }
            binaries = list
        }
        var notes: [String] = []
        if let raw = object["notes"] {
            guard let list = strings(raw), (1...ProviderCatalog.maximumNotes).contains(list.count),
                list.allSatisfy({ SecretsDecoding.label($0, max: 256) })
            else { throw Failure("\(id).notes must list 1 to \(ProviderCatalog.maximumNotes) short lines") }
            notes = list
        }
        return ProviderProfile(
            id: id, displayName: displayName, description: description, endpoints: endpoints,
            credentials: credentials, binaries: binaries, notes: notes)
    }

    static func endpoint(_ value: JSONSpellingValue, at place: String) throws -> ProviderProfile.Endpoint {
        guard let object = value.object else { throw Failure("\(place) must be an object") }
        try SecretsDecoding.onlyKeys(object, ["name", "upstream", "surfaces", "allow"], at: place)
        guard case .string(let name)? = object["name"], identifier(name) else {
            throw Failure("\(place).name must be 1 to 32 lower-case letters, digits or inner -")
        }
        guard case .string(let text)? = object["upstream"], let upstream = SecretsDecoding.httpsUpstream(text) else {
            throw Failure("\(place).upstream must be an https URL without credentials, query, or fragment")
        }
        return ProviderProfile.Endpoint(
            name: name, upstream: upstream,
            surfaces: try SecretsDecoding.surfaces(object["surfaces"], at: "\(place).surfaces"),
            allow: try SecretsDecoding.allow(object["allow"], at: "\(place).allow"))
    }

    static func credential(_ value: JSONSpellingValue, at place: String) throws -> ProviderProfile.Credential {
        guard let object = value.object else { throw Failure("\(place) must be an object") }
        try SecretsDecoding.onlyKeys(object, ["variable", "baseURLEnv", "placeholderPrefix", "endpoint"], at: place)
        guard case .string(let variable)? = object["variable"], SecretsDecoding.variable(variable),
            SecretsDecoding.reservedVariables.contains(variable) == false
        else { throw Failure("\(place).variable must be an environment variable name rv may set") }
        guard case .string(let baseURLEnv)? = object["baseURLEnv"], SecretsDecoding.variable(baseURLEnv),
            SecretsDecoding.reservedVariables.contains(baseURLEnv) == false, baseURLEnv != variable
        else { throw Failure("\(place).baseURLEnv must be a distinct environment variable name rv may set") }
        var prefix = ""
        if let raw = object["placeholderPrefix"] {
            guard case .string(let text) = raw, text.utf8.count <= 32, text.utf8.allSatisfy(SecretsDecoding.placeholderByte)
            else { throw Failure("\(place).placeholderPrefix must be up to 32 letters, digits, _ or -") }
            prefix = text
        }
        guard case .string(let endpoint)? = object["endpoint"] else {
            throw Failure("\(place).endpoint must name one of this profile's endpoints")
        }
        return ProviderProfile.Credential(
            variable: variable, baseURLEnv: baseURLEnv, placeholderPrefix: prefix, endpoint: endpoint)
    }

    static func text(_ value: JSONSpellingValue?, max: Int, at place: String) throws -> String {
        guard case .string(let text)? = value, SecretsDecoding.label(text, max: max) else {
            throw Failure("\(place) must be 1 to \(max) bytes of text")
        }
        return text
    }

    /// Every element must be a string; a mixed array is refused.
    static func strings(_ value: JSONSpellingValue) -> [String]? {
        guard case .array(let items) = value else { return nil }
        var list: [String] = []
        for item in items {
            guard case .string(let text) = item else { return nil }
            list.append(text)
        }
        return list
    }
}
