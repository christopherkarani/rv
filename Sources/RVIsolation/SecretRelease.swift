import Foundation
import RVPolicy

/// Where a released value goes. Each target has its own organization rule
/// and its own rule for what a usable value looks like.
public enum SecretTarget: Sendable, Equatable {
    /// A contained runtime, by the definition's own delivery: an environment
    /// variable, or a gateway entry the runtime spends through a placeholder.
    case cage
    /// A stdio MCP server. It holds the real value in its environment or
    /// arguments, whatever the definition's delivery says.
    case stdioServer
    /// An HTTP header rv sends from the host: a remote MCP server, or `audit forward`.
    case header
}

/// A value cleared for one target, shaped for spending.
public struct ReleasedSecret: Sendable {
    public let definition: SecretDefinition
    /// For an OAuth source, the access token rather than the token endpoint's answer.
    public let value: SecretValue
    /// The value as text. Always set for an environment variable, a stdio server, or a header.
    public let text: String?
    /// The earliest of the definition's expiry and the value's own.
    public let expires: Date?
    /// The source's change marker, read before the value. Only for gateway
    /// entries, the only deliveries that rotate.
    public let version: String?
}

/// Why a release did not happen. A refused release resolves nothing after
/// the refusal, and nothing at all when the refusal is found at admission.
public enum SecretRefusal: Error, Sendable, Equatable {
    /// The organization policy is present but untrustworthy, so nothing is released.
    case policyInvalid(String)
    case refused(secret: String, Reason)

    public enum Reason: Error, Sendable, Equatable {
        case organizationPolicy(SecretOrganizationRule)
        /// An AWS credential set or an OAuth token only the gateway keeps fresh.
        case gatewayOnly
        case expired(at: Date)
        case resolution(SecretResolutionError)
        /// The token endpoint's answer has no usable access token.
        case unusableToken
        /// An AWS profile did not print a usable credential set.
        case unusableCredentials
        /// Not UTF-8 text, or over the environment limit.
        case unusableEnvironmentValue
        case notText
        case lineBreak
    }
}

/// The one place that decides whether a secret leaves the host's providers,
/// for which target, and in what shape.
///
/// Every definition is admitted (organization policy, gateway-only, expiry)
/// before any is resolved, so a refused set mints, unlocks, and prompts for
/// nothing. Values are then resolved together, so one provider can batch them.
public struct SecretRelease: Sendable {
    public static let maximumEnvironmentValueBytes = 8_192

    private let resolver: SecretResolver
    private let policy: ManagedPolicy?
    private let invalidPolicy: String?
    private let now: @Sendable () -> Date

    public init(resolver: SecretResolver, managed: ManagedPolicyState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.resolver = resolver
        policy = managed.policy
        invalidPolicy = managed.invalidReason
        self.now = now
    }

    /// For callers that hold an already-verified policy, or none.
    public init(resolver: SecretResolver, policy: ManagedPolicy?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.resolver = resolver
        self.policy = policy
        invalidPolicy = nil
        self.now = now
    }

    /// Releases every definition to `target`, or none of them.
    public func release(
        _ definitions: [SecretDefinition], to target: SecretTarget
    ) -> Result<[ReleasedSecret], SecretRefusal> {
        if let reason = invalidPolicy { return .failure(.policyInvalid(reason)) }
        for definition in definitions {
            if let reason = admission(definition, to: target) {
                return .failure(.refused(secret: definition.name, reason))
            }
        }
        // Read before the values, so a write in between shows up as a change.
        let versions = definitions.map { definition -> String? in
            guard target == .cage, definition.delivery != .environment else { return nil }
            return resolver.version(definition.source)
        }
        let prefetched = resolver.prefetch(definitions.map(\.source))
        var released: [ReleasedSecret] = []
        for (index, definition) in definitions.enumerated() {
            switch prefetched[index] ?? resolver.resolve(definition.source) {
            case .failure(let error):
                return .failure(.refused(secret: definition.name, .resolution(error)))
            case .success(let value):
                switch shape(definition, value: value, version: versions[index], for: target) {
                case .failure(let reason): return .failure(.refused(secret: definition.name, reason))
                case .success(let secret): released.append(secret)
                }
            }
        }
        return .success(released)
    }

    private func admission(_ definition: SecretDefinition, to target: SecretTarget) -> SecretRefusal.Reason? {
        if let rule = SecretOrganizationRules.rule(definition, policy: policy, target: target) {
            return .organizationPolicy(rule)
        }
        if target != .cage, definition.gatewayOnly { return .gatewayOnly }
        if let expires = definition.expires, now() >= expires { return .expired(at: expires) }
        return nil
    }

    private func shape(
        _ definition: SecretDefinition, value: SecretValue, version: String?, for target: SecretTarget
    ) -> Result<ReleasedSecret, SecretRefusal.Reason> {
        var value = value
        var expires = definition.expires
        if case .oauth = definition.source {
            guard let minted = OAuthAccessToken(value) else { return .failure(.unusableToken) }
            value = minted.token
            expires = [expires, minted.expires].compactMap { $0 }.min()
        }
        if case .awsSigV4 = definition.delivery {
            guard let credentials = AWSCredentialSet(value) else { return .failure(.unusableCredentials) }
            expires = [expires, credentials.expires].compactMap { $0 }.min()
        }
        if let expires, now() >= expires { return .failure(.expired(at: expires)) }
        // `SecretValue` never holds NUL, so text here is safe for argv and headers alike.
        let text = value.text
        switch target {
        case .cage:
            if definition.delivery == .environment {
                guard let text, text.utf8.count <= Self.maximumEnvironmentValueBytes else {
                    return .failure(.unusableEnvironmentValue)
                }
            }
        case .stdioServer:
            guard text != nil else { return .failure(.notText) }
        case .header:
            guard let text else { return .failure(.notText) }
            guard text.unicodeScalars.allSatisfy({ $0 != "\r" && $0 != "\n" }) else { return .failure(.lineBreak) }
        }
        return .success(ReleasedSecret(
            definition: definition, value: value, text: text, expires: expires, version: version))
    }
}

/// One organization rule a definition breaks.
public enum SecretOrganizationRule: Sendable, Equatable {
    /// The policy does not list the definition's source kind.
    case source(kind: SecretSourceKind)
    /// The policy forbids handing the real value to a process's environment.
    case environmentDelivery

    /// The wording `rv secrets`, the launch broker, and `rv report` show.
    public func message(secret: String) -> String {
        switch self {
        case .source(let kind): "\(secret) uses a \(kind.rawValue) source, which is not allowed"
        case .environmentDelivery:
            "\(secret) is delivered as an environment variable, which is not allowed; use the gateway"
        }
    }
}

/// What a managed policy forbids for one secret definition.
public enum SecretOrganizationRules {
    /// The rule `definition` breaks when released to `target`, if any.
    /// The source rule applies everywhere. The environment rule applies to an
    /// environment-delivered secret in a cage, and to every stdio server,
    /// which holds the real value whatever the delivery says.
    public static func rule(
        _ definition: SecretDefinition, policy: ManagedPolicy?, target: SecretTarget
    ) -> SecretOrganizationRule? {
        guard let policy else { return nil }
        if policy.allowsSecretSource(definition.source.kind) == false { return .source(kind: definition.source.kind) }
        guard policy.secrets.allowEnvironmentDelivery == false else { return nil }
        switch target {
        case .cage: return definition.delivery == .environment ? .environmentDelivery : nil
        case .stdioServer: return .environmentDelivery
        case .header: return nil
        }
    }

    /// The source rule alone: for callers that read a secret on the host and
    /// deliver nothing into a cage (scan, hook run).
    public static func sourceViolation(_ definition: SecretDefinition, policy: ManagedPolicy?) -> String? {
        rule(definition, policy: policy, target: .header)?.message(secret: definition.name)
    }

    /// The source rule plus the delivery rule, for secrets that reach a cage.
    public static func violation(_ definition: SecretDefinition, policy: ManagedPolicy?) -> String? {
        rule(definition, policy: policy, target: .cage)?.message(secret: definition.name)
    }
}
