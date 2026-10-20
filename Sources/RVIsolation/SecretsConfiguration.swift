#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Where a secret's real value lives. rv reads it host-side and never stores it.
public enum SecretSource: Sendable, Equatable {
    case keychain(service: String, account: String)
    case hostEnvironment(variable: String)
    /// `op://vault/item/field`, read with the 1Password CLI.
    case onePassword(reference: String)
    /// Vault KV. `address` defaults to `VAULT_ADDR`; the token comes from
    /// `VAULT_TOKEN` or `~/.vault-token`.
    case vault(path: String, field: String, address: URL?)
    /// AWS Secrets Manager via the AWS CLI. `field` picks a key from a JSON secret.
    case awsSecretsManager(secretID: String, field: String?, region: String?)
    /// Infisical via `infisical secrets get`. `environment` is the Infisical env slug.
    case infisical(name: String, project: String?, environment: String?, path: String?)
    /// Bitwarden Secrets Manager via `bws secret get`. `id` is the secret UUID.
    case bitwarden(id: String)
    /// Google Secret Manager via `gcloud secrets versions access`.
    case gcp(secret: String, project: String?, version: String)
    /// Azure Key Vault via `az keyvault secret show`.
    case azure(vault: String, name: String, version: String?)
    /// A `.env` file read host-side at lease time. `path` is absolute;
    /// `variable` is the key inside the file. Values stay in the file.
    case dotenv(path: String, variable: String)

    public var kind: String {
        switch self {
        case .keychain: "keychain"
        case .hostEnvironment: "hostEnvironment"
        case .onePassword: "onePassword"
        case .vault: "vault"
        case .awsSecretsManager: "awsSecretsManager"
        case .infisical: "infisical"
        case .bitwarden: "bitwarden"
        case .gcp: "gcp"
        case .azure: "azure"
        case .dotenv: "dotenv"
        }
    }
}

/// The agent talks to `http://127.0.0.1:<port>/s/<NAME>` (exported in
/// `baseURLEnv`) carrying a placeholder; rv swaps in the real value and
/// forwards only to `upstream`.
public struct SecretGatewayBinding: Sendable, Equatable {
    public var upstream: URL
    public var baseURLEnv: String
    public var placeholderPrefix: String

    public init(upstream: URL, baseURLEnv: String, placeholderPrefix: String = "") {
        self.upstream = upstream
        self.baseURLEnv = baseURLEnv
        self.placeholderPrefix = placeholderPrefix
    }
}

public enum SecretDelivery: Sendable, Equatable {
    case gateway(SecretGatewayBinding)
    /// Real value in the cage environment. Explicit opt-in; weaker.
    case environment
}

public struct SecretDefinition: Sendable, Equatable {
    public var name: String
    public var description: String?
    /// Agent tags this secret stages for. Nil stages for every launch whose
    /// profile lists it, including hook-less shells.
    public var agents: [String]?
    public var source: SecretSource
    public var delivery: SecretDelivery
    /// Varlock `@type`, when the secret was imported from a schema. Not a value.
    public var type: String?

    public init(
        name: String,
        description: String? = nil,
        agents: [String]? = nil,
        source: SecretSource,
        delivery: SecretDelivery,
        type: String? = nil
    ) {
        self.name = name
        self.description = description
        self.agents = agents
        self.source = source
        self.delivery = delivery
        self.type = type
    }

    func stages(forAgent agent: String?) -> Bool {
        guard let agents else { return true }
        guard let agent else { return false }
        return agents.contains(agent)
    }
}

public struct SecretsConfiguration: Sendable, Equatable {
    public static let fileName = "secrets.json"
    public static let maximumBytes = 256 * 1024
    public static let maximumSecrets = 64

    public var secrets: [SecretDefinition]

    public init(secrets: [SecretDefinition] = []) {
        self.secrets = secrets
    }

    public static let empty = SecretsConfiguration()

    public func secret(named name: String) -> SecretDefinition? {
        secrets.first { $0.name == name }
    }
}

public enum SecretsConfigurationError: Error, Sendable, Equatable {
    case unreadable
    case unsafeFile(String)
    case oversized
    case invalid(String)

    public var message: String {
        switch self {
        case .unreadable: "secrets.json could not be read"
        case .unsafeFile(let why): "secrets.json is not safe to use: \(why)"
        case .oversized: "secrets.json is larger than 256 KiB"
        case .invalid(let why): "secrets.json is invalid: \(why)"
        }
    }
}

extension SecretsConfiguration {
    public static func fileURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The environment variable grammar secret names and exported variables use.
    public static func isVariableName(_ name: String) -> Bool {
        SecretsDecoding.variable(name)
    }

    /// A missing file is an empty configuration. Anything else that is not a
    /// regular, owner-owned, non-group/world-writable file is refused.
    public static func load(configDirectory: URL) -> Result<SecretsConfiguration, SecretsConfigurationError> {
        switch OwnerOnlyFile.read(fileURL(configDirectory: configDirectory), maximumBytes: maximumBytes) {
        case .success(let data?): return decode(data)
        case .success(nil): return .success(.empty)
        case .failure(.unsafe(let reason)): return .failure(.unsafeFile(reason))
        case .failure(.oversized): return .failure(.oversized)
        case .failure(.unreadable): return .failure(.unreadable)
        }
    }

    public static func decode(_ data: Data) -> Result<SecretsConfiguration, SecretsConfigurationError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalid("not a JSON object"))
        }
        do {
            try SecretsDecoding.onlyKeys(root, ["version", "secrets"], at: "document")
            guard root["version"] as? Int == 1 else { throw SecretsDecoding.Failure("version must be 1") }
            guard let entries = root["secrets"] as? [Any] else {
                throw SecretsDecoding.Failure("secrets must be an array")
            }
            guard entries.count <= maximumSecrets else {
                throw SecretsDecoding.Failure("at most \(maximumSecrets) secrets")
            }
            var names = Set<String>()
            var exported = Set<String>()
            var secrets: [SecretDefinition] = []
            for (index, entry) in entries.enumerated() {
                let secret = try SecretsDecoding.secret(entry, index: index)
                guard names.insert(secret.name).inserted else {
                    throw SecretsDecoding.Failure("duplicate secret \(secret.name)")
                }
                for variable in secret.exportedVariables {
                    guard exported.insert(variable).inserted else {
                        throw SecretsDecoding.Failure("\(variable) is exported by more than one secret")
                    }
                }
                secrets.append(secret)
            }
            return .success(SecretsConfiguration(secrets: secrets))
        } catch let failure as SecretsDecoding.Failure {
            return .failure(.invalid(failure.reason))
        } catch {
            return .failure(.invalid("unreadable entry"))
        }
    }
}

extension SecretDefinition {
    /// Environment names this secret sets in the cage.
    var exportedVariables: [String] {
        switch delivery {
        case .gateway(let binding): [name, binding.baseURLEnv]
        case .environment: [name]
        }
    }
}

enum SecretsDecoding {
    struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    static let reservedVariables: Set<String> = [
        "PATH", "HOME", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "TERM", "CLICOLOR", "SHELL", "USER",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy",
        "PWD", "OLDPWD", "SHLVL",
    ]

    static func onlyKeys(_ object: [String: Any], _ allowed: Set<String>, at place: String) throws {
        if let unknown = object.keys.first(where: { allowed.contains($0) == false }) {
            throw Failure("unknown key \(DisplayedText.field(unknown)) in \(place)")
        }
    }

    static func secret(_ value: Any, index: Int) throws -> SecretDefinition {
        let place = "secrets[\(index)]"
        guard let object = value as? [String: Any] else { throw Failure("\(place) must be an object") }
        try onlyKeys(object, ["name", "description", "agents", "source", "delivery", "type"], at: place)
        guard let name = object["name"] as? String, variable(name), reservedVariables.contains(name) == false else {
            throw Failure("\(place).name must be an environment variable name")
        }
        var description: String?
        if let raw = object["description"] {
            guard let text = raw as? String, label(text, max: 256) else {
                throw Failure("\(name).description must be short text")
            }
            description = text
        }
        var agents: [String]?
        if let raw = object["agents"] {
            guard let list = raw as? [String], list.count <= 8, list.allSatisfy(AgentTagValidator.isValid),
                Set(list).count == list.count
            else { throw Failure("\(name).agents must be up to 8 distinct agent tags") }
            agents = list.isEmpty ? nil : list
        }
        var typeName: String?
        if let raw = object["type"] {
            guard let text = raw as? String, label(text, max: 128) else {
                throw Failure("\(name).type must be short text")
            }
            typeName = text
        }
        let source = try self.source(object["source"], secret: name)
        let delivery = try self.delivery(object["delivery"], secret: name)
        return SecretDefinition(
            name: name, description: description, agents: agents, source: source, delivery: delivery, type: typeName)
    }

    static func single(_ value: Any?, secret: String, field: String) throws -> (String, [String: Any]) {
        guard let object = value as? [String: Any], object.count == 1,
            let (kind, body) = object.first, let fields = body as? [String: Any]
        else { throw Failure("\(secret).\(field) must name exactly one kind") }
        return (kind, fields)
    }

    static func source(_ value: Any?, secret: String) throws -> SecretSource {
        let (kind, fields) = try single(value, secret: secret, field: "source")
        let place = "\(secret).source.\(kind)"
        switch kind {
        case "keychain":
            try onlyKeys(fields, ["service", "account"], at: place)
            guard let service = fields["service"] as? String, label(service, max: 256),
                let account = fields["account"] as? String, label(account, max: 256)
            else { throw Failure("\(place) needs service and account") }
            return .keychain(service: service, account: account)
        case "hostEnvironment":
            try onlyKeys(fields, ["variable"], at: place)
            guard let variable = fields["variable"] as? String, self.variable(variable) else {
                throw Failure("\(place).variable must be an environment variable name")
            }
            return .hostEnvironment(variable: variable)
        case "onePassword":
            try onlyKeys(fields, ["reference"], at: place)
            guard let reference = fields["reference"] as? String, reference.hasPrefix("op://"),
                label(reference, max: 512), reference.contains(" ") == false
            else { throw Failure("\(place).reference must be an op:// reference") }
            return .onePassword(reference: reference)
        case "vault":
            try onlyKeys(fields, ["path", "field", "address"], at: place)
            guard let path = fields["path"] as? String, vaultPath(path),
                let field = fields["field"] as? String, label(field, max: 128)
            else { throw Failure("\(place) needs a KV path and field") }
            var address: URL?
            if let raw = fields["address"] {
                guard let text = raw as? String, let url = httpsOrigin(text) else {
                    throw Failure("\(place).address must be an https URL")
                }
                address = url
            }
            return .vault(path: path, field: field, address: address)
        case "awsSecretsManager":
            try onlyKeys(fields, ["secretID", "field", "region"], at: place)
            guard let secretID = fields["secretID"] as? String, label(secretID, max: 512),
                secretID.hasPrefix("-") == false
            else { throw Failure("\(place).secretID is required") }
            var field: String?
            if let raw = fields["field"] {
                guard let text = raw as? String, label(text, max: 128) else { throw Failure("\(place).field is invalid") }
                field = text
            }
            var region: String?
            if let raw = fields["region"] {
                guard let text = raw as? String, regionName(text) else { throw Failure("\(place).region is invalid") }
                region = text
            }
            return .awsSecretsManager(secretID: secretID, field: field, region: region)
        case "infisical":
            try onlyKeys(fields, ["name", "project", "environment", "path"], at: place)
            guard let secretName = fields["name"] as? String, cliToken(secretName) else {
                throw Failure("\(place).name is required")
            }
            let project = try optionalToken(fields["project"], "\(place).project")
            let environment = try optionalToken(fields["environment"], "\(place).environment")
            let path = try optionalToken(fields["path"], "\(place).path")
            return .infisical(name: secretName, project: project, environment: environment, path: path)
        case "bitwarden":
            try onlyKeys(fields, ["id"], at: place)
            guard let id = fields["id"] as? String, uuid(id) else {
                throw Failure("\(place).id must be a UUID")
            }
            return .bitwarden(id: id.lowercased())
        case "gcp":
            try onlyKeys(fields, ["secret", "project", "version"], at: place)
            guard let secretName = fields["secret"] as? String, cliToken(secretName) else {
                throw Failure("\(place).secret is required")
            }
            let project = try optionalToken(fields["project"], "\(place).project")
            let version = (fields["version"] as? String) ?? "latest"
            guard cliToken(version) else { throw Failure("\(place).version is invalid") }
            return .gcp(secret: secretName, project: project, version: version)
        case "azure":
            try onlyKeys(fields, ["vault", "name", "version"], at: place)
            guard let vault = fields["vault"] as? String, cliToken(vault),
                let secretName = fields["name"] as? String, cliToken(secretName)
            else { throw Failure("\(place) needs vault and name") }
            let version = try optionalToken(fields["version"], "\(place).version")
            return .azure(vault: vault, name: secretName, version: version)
        case "dotenv":
            try onlyKeys(fields, ["path", "variable"], at: place)
            guard let path = fields["path"] as? String, dotenvPath(path) else {
                throw Failure("\(place).path must be an absolute path without empty or '..' components")
            }
            guard let variable = fields["variable"] as? String, self.variable(variable) else {
                throw Failure("\(place).variable must be an environment variable name")
            }
            return .dotenv(path: path, variable: variable)
        default:
            throw Failure("\(secret).source kind \(DisplayedText.field(kind)) is not supported")
        }
    }

    static func delivery(_ value: Any?, secret: String) throws -> SecretDelivery {
        let (kind, fields) = try single(value, secret: secret, field: "delivery")
        let place = "\(secret).delivery.\(kind)"
        switch kind {
        case "environment":
            try onlyKeys(fields, [], at: place)
            return .environment
        case "gateway":
            try onlyKeys(fields, ["upstream", "baseURLEnv", "placeholderPrefix"], at: place)
            guard let text = fields["upstream"] as? String, let upstream = httpsUpstream(text) else {
                throw Failure("\(place).upstream must be an https URL without credentials, query, or fragment")
            }
            guard let baseURLEnv = fields["baseURLEnv"] as? String, variable(baseURLEnv),
                reservedVariables.contains(baseURLEnv) == false, baseURLEnv != secret
            else { throw Failure("\(place).baseURLEnv must be a distinct environment variable name") }
            let prefix = fields["placeholderPrefix"] as? String ?? ""
            guard prefix.utf8.count <= 32, prefix.utf8.allSatisfy(placeholderByte) else {
                throw Failure("\(place).placeholderPrefix must be up to 32 letters, digits, _ or -")
            }
            return .gateway(SecretGatewayBinding(upstream: upstream, baseURLEnv: baseURLEnv, placeholderPrefix: prefix))
        default:
            throw Failure("\(secret).delivery kind \(DisplayedText.field(kind)) is not supported")
        }
    }

    static func variable(_ value: String) -> Bool {
        guard let first = value.utf8.first, value.utf8.count <= 64,
            (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95
        else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
        }
    }

    /// A CLI argument: no leading dash, no whitespace, no NUL.
    static func cliToken(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 256 && value.hasPrefix("-") == false
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && scalar.value > 32 && scalar != "\"" && scalar != "'" && scalar != "\\"
            }
    }

    static func optionalToken(_ value: Any?, _ place: String) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String, cliToken(text) else { throw Failure("\(place) is invalid") }
        return text
    }

    static func uuid(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == 5, zip(parts, lengths).allSatisfy({ $0.count == $1 }) else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return parts.joined().unicodeScalars.allSatisfy { hex.contains($0) }
    }

    static func label(_ value: String, max: Int) -> Bool {
        value.isEmpty == false && value.utf8.count <= max
            && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: false
                default: true
                }
            }
    }

    static func placeholderByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            || byte == 95 || byte == 45
    }

    static func vaultPath(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 512 && value.hasPrefix("/") == false
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                $0.isEmpty == false && $0 != "." && $0 != ".."
                    && $0.utf8.allSatisfy { placeholderByte($0) || $0 == 46 }
            }
    }

    /// Lexical only: decode never touches the filesystem, so a missing bound
    /// `.env` cannot make config writes fail. Trust checks happen at read time.
    static func dotenvPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.count > 1 && label(value, max: 512)
            && value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
                $0.isEmpty == false && $0 != ".."
            }
    }

    static func regionName(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 32
            && value.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    static func httpsUpstream(_ text: String) -> URL? {
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
            let host = components.host, host.isEmpty == false,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            text.utf8.count <= 512, text.contains("\\") == false
        else { return nil }
        var normalized = components
        normalized.scheme = "https"
        normalized.host = host.lowercased()
        if normalized.path.hasSuffix("/") { normalized.path.removeLast() }
        return normalized.url
    }

    static func httpsOrigin(_ text: String) -> URL? {
        guard let url = httpsUpstream(text), URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.isEmpty == true
        else { return nil }
        return url
    }
}
