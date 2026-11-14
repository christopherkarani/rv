import Foundation
import RVDomain

/// A provider profile resolved for one secret: everything a gateway
/// delivery needs. Never wider than the profile endpoint it came from.
public struct ProviderExpansion: Sendable, Equatable {
    public var profile: String
    public var endpoint: String
    public var upstream: URL
    public var baseURLEnv: String
    public var placeholderPrefix: String
    public var surfaces: Set<GatewaySurface>
    public var allow: [GatewayAllowance]
    public var binaries: [String]?

    public init(
        profile: String, endpoint: String, upstream: URL, baseURLEnv: String, placeholderPrefix: String,
        surfaces: Set<GatewaySurface>, allow: [GatewayAllowance], binaries: [String]?
    ) {
        self.profile = profile
        self.endpoint = endpoint
        self.upstream = upstream
        self.baseURLEnv = baseURLEnv
        self.placeholderPrefix = placeholderPrefix
        self.surfaces = surfaces
        self.allow = allow
        self.binaries = binaries
    }
}

public enum ProviderExpansionError: Error, Sendable, Equatable {
    case unknownProvider(String)
    case unknownEndpoint(profile: String, endpoint: String)
    /// The secret is not one of the profile's variables and the profile has several endpoints.
    case endpointAmbiguous(profile: String, endpoints: [String])
    case needsBaseURLEnv(profile: String, endpoint: String)
    case widerSurface(profile: String, surface: GatewaySurface)
    case widerAllow(profile: String, allowance: String)

    public var message: String {
        switch self {
        case .unknownProvider(let id):
            "no provider profile \(DisplayedText.field(id)); `rv secrets providers` lists them"
        case .unknownEndpoint(let profile, let endpoint):
            "provider \(profile) has no endpoint \(DisplayedText.field(endpoint)); `rv secrets providers \(profile)` lists them"
        case .endpointAmbiguous(let profile, let endpoints):
            "provider \(profile) has several endpoints; pick one with --provider "
                + endpoints.map { "\(profile):\($0)" }.joined(separator: " or ")
        case .needsBaseURLEnv(let profile, let endpoint):
            "provider \(profile):\(endpoint) has no default variable for this name; pass --base-url-env VAR"
        case .widerSurface(let profile, let surface):
            "--surface \(surface.rawValue) is wider than provider \(profile) allows"
        case .widerAllow(let profile, let allowance):
            "--allow \(DisplayedText.field(allowance)) is wider than provider \(profile)'s rules; "
                + "--provider can only be narrowed"
        }
    }
}

extension ProviderCatalog {
    /// Resolves `selector` (`id` or `id:endpoint`) for secret `name`. The
    /// endpoint is the one named, else the one `name` is a credential of,
    /// else the profile's only endpoint. `baseURLEnv` and a non-empty
    /// `placeholderPrefix` replace the credential's names; they carry no
    /// authority. `surfaces` and `allow` may only narrow the endpoint's own:
    /// each surface must be one it lists, and each allow rule must fall
    /// inside one of its rules.
    public func expand(
        _ selector: String, secret name: String, baseURLEnv: String?, placeholderPrefix: String,
        surfaces: Set<GatewaySurface>?, allow: [GatewayAllowance]
    ) -> Result<ProviderExpansion, ProviderExpansionError> {
        let parts = selector.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let profile = profile(id: parts[0]) else { return .failure(.unknownProvider(parts[0])) }
        let credential = profile.credentials.first { $0.variable == name }
        let endpoint: ProviderProfile.Endpoint
        if parts.count == 2 {
            guard let named = profile.endpoint(named: parts[1]) else {
                return .failure(.unknownEndpoint(profile: profile.id, endpoint: parts[1]))
            }
            endpoint = named
        } else if let credential, let bound = profile.endpoint(named: credential.endpoint) {
            endpoint = bound
        } else if profile.endpoints.count == 1 {
            endpoint = profile.endpoints[0]
        } else {
            return .failure(.endpointAmbiguous(profile: profile.id, endpoints: profile.endpoints.map(\.name)))
        }
        let own = credential.flatMap { $0.endpoint == endpoint.name ? $0 : nil }
        guard let variable = baseURLEnv ?? own?.baseURLEnv else {
            return .failure(.needsBaseURLEnv(profile: profile.id, endpoint: endpoint.name))
        }
        if let surfaces, let wider = GatewaySurface.ordered(surfaces.subtracting(endpoint.surfaces)).first {
            return .failure(.widerSurface(profile: profile.id, surface: wider))
        }
        let outer = endpoint.allow.flatMap(\.rules)
        if outer.isEmpty == false {
            for allowance in allow where allowance.rules.allSatisfy({ inner in outer.contains { inner.isWithin($0) } }) == false {
                return .failure(.widerAllow(profile: profile.id, allowance: allowance.text))
            }
        }
        return .success(ProviderExpansion(
            profile: profile.id, endpoint: endpoint.name, upstream: endpoint.upstream, baseURLEnv: variable,
            placeholderPrefix: placeholderPrefix.isEmpty ? (own?.placeholderPrefix ?? "") : placeholderPrefix,
            surfaces: surfaces ?? endpoint.surfaces, allow: allow.isEmpty ? endpoint.allow : allow,
            binaries: profile.binaries))
    }
}

extension GatewayAccessRule {
    /// Whether every request this rule permits, `outer` permits too. Sound,
    /// not complete: a `false` may be a rule that is in fact narrower, never
    /// the reverse.
    func isWithin(_ outer: GatewayAccessRule) -> Bool {
        switch (methods, outer.methods) {
        case (_, nil): break
        case (nil, _?): return false
        case (let inner?, let wider?): guard inner.isSubset(of: wider) else { return false }
        }
        // Each query condition of `outer` must hold whenever this rule's do.
        guard outer.query.allSatisfy({ query[$0.key] == $0.value }) else { return false }
        return GatewayAccess.glob(path, isWithin: outer.path)
    }
}

extension GatewayAccess {
    /// Whether every path `inner` matches, `outer` matches too. A literal
    /// segment of `inner` must match `outer`'s segment; a wildcard segment
    /// only `*` or the same text; `**` only `**`.
    static func glob(_ inner: String, isWithin outer: String) -> Bool {
        let inner = inner.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let outer = outer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // memo[i][j]: inner[i...] within outer[j...]; nil until computed.
        var memo = [[Bool?]](repeating: [Bool?](repeating: nil, count: outer.count + 1), count: inner.count + 1)
        func within(_ i: Int, _ j: Int) -> Bool {
            if let known = memo[i][j] { return known }
            let result: Bool
            if j == outer.count {
                result = i == inner.count
            } else if outer[j] == "**" {
                result = within(i, j + 1) || (i < inner.count && within(i + 1, j))
            } else if i == inner.count || inner[i] == "**" {
                result = false
            } else {
                result = segment(inner[i], isWithin: outer[j]) && within(i + 1, j + 1)
            }
            memo[i][j] = result
            return result
        }
        return within(0, 0)
    }

    private static func segment(_ inner: String, isWithin outer: String) -> Bool {
        guard inner.contains("*") else {
            return glob("/" + outer, matches: "/" + inner)
        }
        return outer == "*" || outer == inner
    }
}
