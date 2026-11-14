#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation

/// Why a server that lists `placeholders` is not started. It is refused on
/// its own: the other servers still start.
public enum MCPPlaceholderRefusal: Error, Sendable, Equatable {
    case unsupportedPlatform
    /// The platform could cage it, but this launch does not enforce the cage.
    case cageUnavailable
    case noSandbox
    case unconfinedNetwork
    /// The server would also hold the real value of these placeholders: by
    /// name (`secrets`, `${secret:NAME}` in `args`), or as the value of
    /// another secret, an `env` literal or an argument.
    case realValueToo(String)
    case unknownSecret(String)
    case environmentDelivery(String)
    /// Read from rv's own environment, which the MCP client that started
    /// rv (and every server it starts directly) also has.
    case hostEnvironmentSource(String)
    /// Its upstream is neither https nor loopback.
    case plaintextUpstream(String)
    case agentScoped(secret: String, agents: [String])
    case approvalRules(String)
    /// A placeholder variable the server's `env`, `secrets` or base environment already sets.
    case variableCollision(String)
    case capabilityUnavailable(String)
    case leaseFailed(String)
    /// The sandbox hook returned a launch that does not run under `sandbox-exec`.
    case uncaged

    public var message: String {
        switch self {
        case .unsupportedPlatform:
            "placeholders need a server started suspended in its own process group, which only macOS supports today"
        case .cageUnavailable:
            "placeholders need the MCP server sandbox, which this launch does not enforce"
        case .noSandbox:
            "placeholders need a sandbox; add \"sandbox\" to its mcp.json entry"
        case .unconfinedNetwork:
            "placeholders need sandbox.network false (list the hosts it needs in sandbox.hosts)"
        case .realValueToo(let names):
            "the server would also hold the real value of \(names) (through secrets, env or args); "
                + "a server gets a secret one way"
        case .unknownSecret(let name):
            "secret \(name) is not defined in secrets.json"
        case .environmentDelivery(let name):
            "secret \(name) is delivered as an environment variable, so its real value would be in the server's "
                + "environment; only gateway and awsSigV4 secrets can be placeholders"
        case .hostEnvironmentSource(let name):
            "secret \(name) is read from rv's own environment, which the MCP client that started rv also holds; "
                + "store it in a secret store (keychain, 1Password, ...) to use it as a placeholder"
        case .plaintextUpstream(let name):
            "secret \(name) is sent to an upstream that is neither https nor loopback"
        case .agentScoped(let name, let agents):
            "secret \(name) stages only for \(agents.joined(separator: ", ")); an MCP server carries no agent tag"
        case .approvalRules(let name):
            "secret \(name) has approve rules, and no approver can answer for an MCP server; remove them or use it "
                + "from a workspace"
        case .variableCollision(let variable):
            "placeholder variable \(variable) is already set by the server's env or secrets"
        case .capabilityUnavailable(let reason):
            "placeholders cannot be bound to the server here: \(reason)"
        case .leaseFailed(let reason):
            "placeholders could not be staged: \(reason)"
        case .uncaged:
            "the server would not run inside the sandbox, so no placeholders are staged"
        }
    }
}

/// Where placeholder leases come from. `rv mcp serve` passes one over its
/// secrets gateway; with `unavailable` every server with placeholders is
/// refused.
public struct MCPPlaceholderLeasing: Sendable {
    #if os(macOS)
    static let supportedPlatform = true
    #else
    static let supportedPlatform = false
    #endif

    /// Whether a server can be started suspended and bound to its group here.
    var platformSupported: Bool
    /// Why leases cannot be bound to a spawned group here, or nil. Asked at
    /// most once per plan, before any secret is resolved.
    var capability: @Sendable () -> String?
    var lease: @Sendable (_ server: String, _ secrets: [String]) -> Result<SecretPlaceholderLease, SecretPlaceholderLeaseError>

    public static let unavailable = MCPPlaceholderLeasing(
        platformSupported: supportedPlatform,
        capability: { "no secrets gateway was started for this launch" },
        lease: { _, _ in .failure(.gatewayUnavailable) })

    package static func broker(_ broker: SecretPlaceholderBroker) -> MCPPlaceholderLeasing {
        MCPPlaceholderLeasing(
            platformSupported: supportedPlatform,
            capability: { broker.capabilityRefusal() },
            lease: { server, names in broker.lease(names, server: server) })
    }
}

/// The lease a placeholder-bound server starts with. Compared by identity.
public struct MCPPlaceholderBinding: Sendable, Equatable {
    let lease: SecretPlaceholderLease

    public static func == (lhs: MCPPlaceholderBinding, rhs: MCPPlaceholderBinding) -> Bool {
        lhs.lease === rhs.lease
    }
}

/// The decisions for a server with placeholders, over values only.
package enum MCPPlaceholderPlanning {
    /// Why `definition` gets no placeholders, judged before anything is
    /// resolved, or nil. `secrets` is secrets.json as serve loaded it; the
    /// lease checks the definitions it loads itself again. An untrusted
    /// mcp.json never gets here: the plan refuses it whole.
    static func refusal(
        _ definition: MCPServerDefinition, platformSupported: Bool, cageEnforced: Bool, secrets: SecretsConfiguration
    ) -> MCPPlaceholderRefusal? {
        guard platformSupported else { return .unsupportedPlatform }
        guard cageEnforced else { return .cageUnavailable }
        guard let sandbox = definition.sandbox else { return .noSandbox }
        if sandbox.network { return .unconfinedNetwork }
        let realValues = Set(definition.secrets.values)
            .union(definition.args.flatMap { MCPSecretReference.names(in: $0) ?? [] })
        for name in definition.placeholders {
            if realValues.contains(name) { return .realValueToo(name) }
            guard let secret = secrets.secret(named: name) else { return .unknownSecret(name) }
            guard let upstream = upstream(secret) else { return .environmentDelivery(name) }
            if SecretPlaceholderBroker.isHostEnvironmentSourced(secret) { return .hostEnvironmentSource(name) }
            if protected(upstream) == false { return .plaintextUpstream(name) }
            if secret.stages(forAgent: nil) == false { return .agentScoped(secret: name, agents: secret.agents ?? []) }
            if SecretPlaceholderBroker.hasApprovalRules(secret) { return .approvalRules(name) }
            for variable in secret.stagedVariables
            where definition.environment[variable] != nil || definition.secrets[variable] != nil {
                return .variableCollision(variable)
            }
        }
        return nil
    }

    /// Where the gateway sends `secret`'s real value; nil for one delivered
    /// in the environment.
    package static func upstream(_ secret: SecretDefinition) -> URL? {
        switch secret.delivery {
        case .gateway(let binding): binding.upstream
        case .awsSigV4(let binding): binding.upstream
        case .environment: nil
        }
    }

    /// `scheme://host[:port]`, as the trust review names an upstream.
    package static func origin(_ url: URL) -> String {
        let host = url.host.map { $0.contains(":") && $0.hasPrefix("[") == false ? "[\($0)]" : $0 } ?? ""
        return "\(url.scheme ?? "")://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// https, or plain http to this host only.
    static func protected(_ url: URL) -> Bool {
        switch (url.scheme ?? "").lowercased() {
        case "https": true
        // Foundation gives an IPv6 host with or without its brackets, by version.
        case "http": ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        default: false
        }
    }

    /// `environment` with the lease's variables added. One that is already
    /// set is a collision: a placeholder never replaces a value, nor a value
    /// a placeholder.
    static func merge(
        _ environment: [String: String], lease: [(name: String, value: String)]
    ) -> Result<[String: String], MCPPlaceholderRefusal> {
        var merged = environment
        for entry in lease {
            guard merged[entry.name] == nil else { return .failure(.variableCollision(entry.name)) }
            merged[entry.name] = entry.value
        }
        return .success(merged)
    }
}

/// When serve's shutdown signals a placeholder server's group, counted from
/// `started`, when this server's own shutdown began: nothing during `grace`
/// (it may exit on its own), then `SIGTERM` once, then `terminateGrace`
/// after that `SIGKILL` once. Nothing once the leader has exited.
struct MCPPlaceholderShutdown: Equatable {
    enum Step: Equatable {
        case waiting
        case terminated(at: Date)
        case killed
    }

    static let grace: TimeInterval = 2
    static let terminateGrace: TimeInterval = 1

    let started: Date
    private(set) var step = Step.waiting

    init(started: Date) {
        self.started = started
    }

    /// When serve stops waiting for this group and leaves it to the broker's stop.
    var giveUp: Date {
        started.addingTimeInterval(Self.grace + Self.terminateGrace + 2)
    }

    mutating func signal(exited: Bool, now: Date) -> Int32? {
        guard exited == false else { return nil }
        switch step {
        case .waiting:
            guard now.timeIntervalSince(started) >= Self.grace else { return nil }
            step = .terminated(at: now)
            return SIGTERM
        case .terminated(let sent):
            guard now.timeIntervalSince(sent) >= Self.terminateGrace else { return nil }
            step = .killed
            return SIGKILL
        case .killed:
            return nil
        }
    }
}
