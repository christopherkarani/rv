#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVHistory
import RVIsolation
import Synchronization

/// How to start one upstream server process.
public struct MCPUpstreamLaunch: Sendable, Equatable {
    public var server: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        server: String, executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String? = nil
    ) {
        self.server = server
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// Whether the leases for this plan's placeholder servers can be bound
/// here, asked once and only when a server lists placeholders.
enum MCPPlaceholderCapability {
    case unprobed
    case available
    case unavailable(String)
}

public enum MCPLaunchError: Error, Sendable, Equatable {
    case unknownServer(String)
    case blocked(String)
    case secretUndefined(server: String, secret: String)
    case secretUnavailable(server: String, secret: String, reason: String)
    case sandbox(String)
    /// mcp.json was not written by rv. A remote entry would send stored
    /// tokens and header secrets to whatever URL the file now names.
    case untrustedRemote(String)

    public var message: String {
        switch self {
        case .unknownServer(let name): "mcp.json has no server named \(MCPDisplayedText.field(name))"
        case .blocked(let name): "\(MCPDisplayedText.field(name)) is blocked by mcp.json or organization policy"
        case .secretUndefined(let server, let secret): "\(server) uses secret \(secret), which secrets.json does not define"
        case .secretUnavailable(let server, let secret, let reason): "\(server) could not read secret \(secret): \(reason)"
        case .sandbox(let reason): "sandbox: \(reason)"
        case .untrustedRemote(let name):
            "\(name) is in an untrusted mcp.json, so rv will not start it, resolve its secrets, or send its tokens"
        }
    }
}

/// Turns `mcp.json` definitions into processes the runtime can start.
public enum MCPLaunchPlanner {
    /// `PATH` lookup happens in `/usr/bin/env` against the upstream's own environment.
    public static let envPath = "/usr/bin/env"

    public static func plan(
        servers names: [String],
        configuration: MCPConfiguration,
        secrets: SecretsConfiguration,
        resolver: SecretResolver,
        baseEnvironment: [String: String],
        requireSandbox: Bool = MCPSandbox.enforced,
        oauthTokens: (String) -> MCPOAuthTokens? = { _ in nil },
        sandbox: (MCPServerDefinition, MCPUpstreamLaunch, MCPCageReach) -> Result<MCPUpstreamLaunch, MCPLaunchError> = { _, launch, _ in .success(launch) },
        placeholders: MCPPlaceholderLeasing = .unavailable,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> Result<[(MCPGatewayCore.Upstream, MCPUpstreamConnection)], MCPLaunchError> {
        // A plan that fails starts nothing: the leases it took end with it,
        // and so do the proxies its cages started.
        var leases: [SecretPlaceholderLease] = []
        var caged: [String] = []
        let planned = planServers(
            names, configuration: configuration, secrets: secrets, resolver: resolver, baseEnvironment: baseEnvironment,
            requireSandbox: requireSandbox, oauthTokens: oauthTokens,
            sandbox: { definition, launch, reach in
                caged.append(definition.name)
                return sandbox(definition, launch, reach)
            },
            placeholders: placeholders, leases: &leases, now: now)
        if case .failure = planned {
            for lease in leases { lease.revoke() }
            for server in caged { MCPSandbox.stopProxies(server: server) }
        }
        return planned
    }

    private static func planServers(
        _ names: [String], configuration: MCPConfiguration, secrets: SecretsConfiguration, resolver: SecretResolver,
        baseEnvironment: [String: String], requireSandbox: Bool, oauthTokens: (String) -> MCPOAuthTokens?,
        sandbox: (MCPServerDefinition, MCPUpstreamLaunch, MCPCageReach) -> Result<MCPUpstreamLaunch, MCPLaunchError>,
        placeholders: MCPPlaceholderLeasing, leases: inout [SecretPlaceholderLease],
        now: @escaping @Sendable () -> Date
    ) -> Result<[(MCPGatewayCore.Upstream, MCPUpstreamConnection)], MCPLaunchError> {
        var planned: [(MCPGatewayCore.Upstream, MCPUpstreamConnection)] = []
        var capability = MCPPlaceholderCapability.unprobed
        for name in names {
            if configuration.untrusted { return .failure(.untrustedRemote(name)) }
            if configuration.isBlocked(name) { return .failure(.blocked(name)) }
            guard let definition = configuration.server(named: name) else { return .failure(.unknownServer(name)) }
            if let remote = definition.remote {
                let resolved: [String: String]
                switch resolve(
                    remote.secretNames, server: name, configuration: configuration, secrets: secrets, resolver: resolver,
                    into: .remoteHeader, now: now)
                {
                case .failure(let error): return .failure(error)
                case .success(let values): resolved = values
                }
                let headers = remote.headers.mapValues { MCPSecretReference.substitute($0, values: resolved) }
                let loaded = remote.headers.keys.contains { $0.lowercased() == "authorization" } ? nil : oauthTokens(name)
                let tokens = loaded.flatMap { candidate -> MCPOAuthTokens? in
                    guard let resource = URL(string: candidate.resource), MCPOAuth.sameResource(resource, remote.url) else {
                        return nil
                    }
                    return candidate
                }
                let launch = MCPRemoteLaunch(
                    server: name, url: remote.url, headers: headers, transport: remote.transport, oauth: tokens,
                    answerTimeout: MCPRemoteLaunch.answerTimeout(
                        callTimeoutSeconds: definition.callTimeoutSeconds,
                        startTimeoutSeconds: definition.startTimeoutSeconds))
                let scrubbed = named(resolved) + (tokens.map(MCPGatewayCore.oauthSecrets) ?? [])
                planned.append((MCPGatewayCore.Upstream(definition: definition, secretValues: scrubbed), .remote(launch)))
                continue
            }
            // Before anything is resolved: a secret named in `args` would
            // land in the process's arguments, where `ps` shows it.
            if let secret = argumentSecret(definition) {
                planned.append(refused(definition, .secretInArguments(secret)))
                continue
            }
            if definition.placeholders.isEmpty == false {
                switch placeholderServer(
                    definition, configuration: configuration, secrets: secrets, resolver: resolver,
                    baseEnvironment: baseEnvironment, requireSandbox: requireSandbox, placeholders: placeholders,
                    capability: &capability, sandbox: sandbox, now: now)
                {
                case .failure(let error): return .failure(error)
                case .success(let entry):
                    if case .placeholderBound(_, let binding) = entry.1 { leases.append(binding.lease) }
                    planned.append(entry)
                }
                continue
            }
            switch sealRefusal(definition, configuration: configuration, requireSandbox: requireSandbox) {
            case .refusedAlone(let reason)?:
                // Refused alone, before its secrets are resolved or a cage
                // is made: the other servers still serve.
                planned.append(refused(definition, .sandbox(reason)))
                continue
            case .failsPlan(let reason)?:
                return .failure(.sandbox(reason))
            case nil: break
            }
            var environment = sandboxEnvironment(baseEnvironment)
            for (key, value) in definition.environment { environment[key] = value }
            let resolved: [String: String]
            switch resolve(
                referencedSecrets(definition), server: name, configuration: configuration, secrets: secrets, resolver: resolver,
                into: .stdioProcess, now: now)
            {
            case .failure(let error): return .failure(error)
            case .success(let values): resolved = values
            }
            // Secrets reach the server only through its environment;
            // `argumentSecret` refused any `${secret:}` in its args above.
            for (variable, secretName) in definition.secrets { environment[variable] = resolved[secretName] }
            let launch = MCPUpstreamLaunch(
                server: name, executable: envPath, arguments: [definition.command] + definition.args,
                environment: environment)
            switch sandbox(definition, launch, .standard) {
            case .failure(let error): return .failure(error)
            case .success(let caged):
                var scrubbed = named(resolved)
                if let credential = MCPSandbox.proxyCredential(in: caged.environment) {
                    scrubbed.append((name: "HTTPS_PROXY", value: credential))
                }
                planned.append((MCPGatewayCore.Upstream(definition: definition, secretValues: scrubbed), .process(caged)))
            }
        }
        return .success(planned)
    }

    /// A local server with `placeholders`: real values for its `secrets` as
    /// for any server, placeholders leased for the rest, and a cage
    /// that may reach the secrets gateway. A placeholder refusal refuses this
    /// server only (`.refused`); a failure any server would hit fails the plan.
    /// Every refusal that needs no value comes before its own secrets are
    /// resolved; only the real-value and cage checks come after.
    static func placeholderServer(
        _ definition: MCPServerDefinition, configuration: MCPConfiguration, secrets: SecretsConfiguration,
        resolver: SecretResolver, baseEnvironment: [String: String], requireSandbox: Bool,
        placeholders: MCPPlaceholderLeasing, capability: inout MCPPlaceholderCapability,
        sandbox: (MCPServerDefinition, MCPUpstreamLaunch, MCPCageReach) -> Result<MCPUpstreamLaunch, MCPLaunchError>,
        now: @escaping @Sendable () -> Date
    ) -> Result<(MCPGatewayCore.Upstream, MCPUpstreamConnection), MCPLaunchError> {
        let name = definition.name
        func refuse(_ refusal: MCPPlaceholderRefusal) -> Result<(MCPGatewayCore.Upstream, MCPUpstreamConnection), MCPLaunchError> {
            .success(refused(definition, .placeholder(refusal)))
        }
        if let refusal = MCPPlaceholderPlanning.refusal(
            definition, platformSupported: placeholders.platformSupported, cageEnforced: requireSandbox, secrets: secrets)
        {
            return refuse(refusal)
        }
        if let reason = capabilityRefusal(&capability, placeholders) { return refuse(.capabilityUnavailable(reason)) }
        let lease: SecretPlaceholderLease
        switch placeholders.lease(name, definition.placeholders) {
        case .failure(let error): return refuse(.leaseFailed(error.message))
        case .success(let leased): lease = leased
        }
        var environment = sandboxEnvironment(baseEnvironment)
        for (key, value) in definition.environment { environment[key] = value }
        switch MCPPlaceholderPlanning.merge(environment, lease: lease.environment) {
        case .failure(let refusal):
            lease.revoke()
            return refuse(refusal)
        case .success(let merged): environment = merged
        }
        // The lease's own definitions may differ from the ones checked above.
        if let clash = lease.environment.first(where: { definition.secrets[$0.name] != nil }) {
            lease.revoke()
            return refuse(.variableCollision(clash.name))
        }
        let resolved: [String: String]
        switch resolve(
            referencedSecrets(definition), server: name, configuration: configuration, secrets: secrets, resolver: resolver,
            into: .stdioProcess, now: now)
        {
        case .failure(let error):
            lease.revoke()
            return .failure(error)
        case .success(let values): resolved = values
        }
        for (variable, secretName) in definition.secrets { environment[variable] = resolved[secretName] }
        let launch = MCPUpstreamLaunch(
            server: name, executable: envPath, arguments: [definition.command] + definition.args,
            environment: environment)
        // By value, under any name: an alias secret, an `env` literal, an argument.
        if lease.holdsRealValue(environment: launch.environment, arguments: launch.arguments) {
            lease.revoke()
            return refuse(.realValueToo(definition.placeholders.joined(separator: ", ")))
        }
        switch sandbox(definition, launch, .secretsGateway(port: lease.gatewayPort)) {
        case .failure(let error):
            lease.revoke()
            return .failure(error)
        case .success(let caged):
            guard caged.executable == MCPSandbox.sandboxExec else {
                lease.revoke()
                if MCPSandbox.proxyCredential(in: caged.environment) != nil { MCPSandbox.stopProxies(server: name) }
                return refuse(.uncaged)
            }
            var scrubbed = named(resolved)
            if let credential = MCPSandbox.proxyCredential(in: caged.environment) {
                scrubbed.append((name: "HTTPS_PROXY", value: credential))
            }
            return .success((
                MCPGatewayCore.Upstream(definition: definition, secretValues: scrubbed),
                .placeholderBound(caged, MCPPlaceholderBinding(lease: lease))))
        }
    }

    /// How a local server without placeholders is refused for its
    /// sandbox, judged from mcp.json alone before anything is resolved.
    package enum SealRefusal: Sendable, Equatable {
        /// Not started; the other servers still serve.
        case refusedAlone(String)
        /// The whole plan fails.
        case failsPlan(String)
    }

    /// Where the cage is enforced (`requireSandbox`), a server needs a
    /// sandbox with the network closed (hosts listed in sandbox.hosts).
    /// Where it is not, the organization's `requireSandbox` is kept only by
    /// starting nothing. `rv mcp list` asks the same question.
    package static func sealRefusal(
        _ definition: MCPServerDefinition, configuration: MCPConfiguration, requireSandbox: Bool
    ) -> SealRefusal? {
        let name = definition.name
        if requireSandbox {
            guard let policy = definition.sandbox else {
                return .refusedAlone("\(name) needs a sandbox; add \"sandbox\" to its mcp.json entry")
            }
            if policy.network {
                return .refusedAlone("\(name) stays off the network; list the hosts it needs in sandbox.hosts")
            }
            return nil
        }
        if configuration.managed?.mcp.requireSandbox == true {
            return .failsPlan(MCPPlatformSupport.organizationSandboxUnenforced(server: name))
        }
        return nil
    }

    /// The secrets a local server's launch resolves: its `secrets` values,
    /// delivered as environment variables. A `${secret:}` in `args` is
    /// never resolved (`argumentSecret` refuses the server first).
    package static func referencedSecrets(_ definition: MCPServerDefinition) -> [String] {
        Set(definition.secrets.values).sorted()
    }

    /// How a local server's `args` would put a secret in its command line,
    /// or nil. Such a server is not started: arguments are readable by
    /// every user on the machine (`ps`, `/proc/<pid>/cmdline`), so a secret
    /// goes by environment variable or not at all.
    ///
    /// Two ways, checked whatever the command is:
    /// - `${secret:NAME}` in an arg. An arg that is not a valid template
    ///   counts too: rv does not guess what it would expand to.
    /// - `$VAR` or `${VAR}` for a variable in its `secrets`. A shell
    ///   (`sh -c "srv --token $VAR"`) or any launcher that expands it puts
    ///   the value in its child's arguments.
    package static func argumentSecret(_ definition: MCPServerDefinition) -> MCPArgumentSecret? {
        guard definition.remote == nil else { return nil }
        for arg in definition.args where arg.contains("${secret:") {
            return .reference(MCPSecretReference.names(in: arg)?.first ?? "?")
        }
        let variables = Set(definition.secrets.keys)
        guard variables.isEmpty == false else { return nil }
        for arg in definition.args {
            if let variable = MCPArgumentSecret.expandedVariables(in: arg).first(where: variables.contains) {
                return .expanded(variable: variable, secret: definition.secrets[variable] ?? variable)
            }
        }
        return nil
    }

    /// Why a server with a secret in its arguments is off, and the fix, on
    /// one line.
    package static func argumentSecretMessage(_ found: MCPArgumentSecret) -> String {
        found.reason + " to every user; " + found.fix
    }

    /// A server planned not to start: no secret values, no launch.
    static func refused(
        _ definition: MCPServerDefinition, _ refusal: MCPServerRefusal
    ) -> (MCPGatewayCore.Upstream, MCPUpstreamConnection) {
        (MCPGatewayCore.Upstream(definition: definition, secretValues: []), .refused(server: definition.name, refusal))
    }

    /// Why leases cannot be bound here, probed the first time a server asks:
    /// before anything is resolved, so a server that cannot be bound never
    /// prompts or unlocks.
    static func capabilityRefusal(
        _ capability: inout MCPPlaceholderCapability, _ placeholders: MCPPlaceholderLeasing
    ) -> String? {
        switch capability {
        case .unprobed:
            let reason = placeholders.capability()
            capability = reason.map { .unavailable($0) } ?? .available
            return reason
        case .available: return nil
        case .unavailable(let reason): return reason
        }
    }

    static func named(_ resolved: [String: String]) -> [(name: String, value: String)] {
        resolved.keys.sorted().compactMap { key in resolved[key].map { (name: key, value: $0) } }
    }

    /// Where resolved values go.
    enum SecretTarget {
        /// Sent as a header by the host-side gateway; never in a child process.
        case remoteHeader
        /// Real values in a child's environment and arguments.
        case stdioProcess
    }

    static func resolve(
        _ names: [String], server: String, configuration: MCPConfiguration, secrets: SecretsConfiguration,
        resolver: SecretResolver, into target: SecretTarget, now: @escaping @Sendable () -> Date
    ) -> Result<[String: String], MCPLaunchError> {
        var definitions: [SecretDefinition] = []
        for secretName in names {
            guard let secret = secrets.secret(named: secretName) else {
                return .failure(.secretUndefined(server: server, secret: secretName))
            }
            definitions.append(secret)
        }
        let release = SecretRelease(resolver: resolver, policy: configuration.managed, now: now)
        switch release.release(definitions, to: target == .stdioProcess ? .stdioServer : .header) {
        case .failure(.policyInvalid(let reason)):
            return .failure(.secretUnavailable(
                server: server, secret: names.first ?? "", reason: "organization policy is invalid: \(reason)"))
        case .failure(.refused(let secretName, let reason)):
            let kind = secrets.secret(named: secretName)?.source.kind.rawValue ?? ""
            return .failure(.secretUnavailable(server: server, secret: secretName, reason: unavailable(reason, kind: kind)))
        case .success(let released):
            var resolved: [String: String] = [:]
            for secret in released { resolved[secret.definition.name] = secret.text }
            return .success(resolved)
        }
    }

    static func unavailable(_ reason: SecretRefusal.Reason, kind: String) -> String {
        switch reason {
        case .gatewayOnly: "\(kind) secrets are spent only by the secret gateway, not by MCP servers"
        case .organizationPolicy(.source): "organization policy does not allow \(kind) secrets"
        // A stdio server holds the real value whatever the secret's own
        // `delivery` says, so environment-only policy forbids it outright.
        case .organizationPolicy(.environmentDelivery):
            "organization policy sets secrets.allowEnvironmentDelivery to false, "
                + "and a stdio server receives secrets in its environment"
        case .expired(let date): "expired at \(SecretExpiry.text(date))"
        case .resolution(let error): error.message
        case .unusableToken, .unusableCredentials, .unusableEnvironmentValue, .notText, .lineBreak: "not usable as text"
        }
    }

    /// Host environment a sandboxed upstream may see. Credentials the host
    /// already exported (`AWS_*`, `GITHUB_TOKEN`, …) are not copied.
    static func sandboxEnvironment(_ base: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (key, value) in base where key == "PATH" || key == "HOME" || key == "TMPDIR" || key == "LANG" || key.hasPrefix("LC_") {
            kept[key] = value
        }
        return kept
    }
}

/// Runs a gateway core over real pipes: the client on `input`/`output`
/// (normally stdin/stdout), upstreams as child processes. One serial queue
/// owns the core; reader threads only parse lines and enqueue them.
public final class MCPGatewayRuntime: @unchecked Sendable {
    public static let maximumLineBytes = 64 * 1024 * 1024
    /// What may wait for one upstream before it counts as not reading: two
    /// maximum lines. The client has no such bound: what waits for it is
    /// held back at its source (`readerBacklogBytes` per reader), and it is
    /// not reading once it takes nothing for `clientStallSeconds`.
    public static let writeBufferBytes = 2 * maximumLineBytes
    /// How far one reader (the client's, or one upstream's) may run ahead of
    /// the gateway queue, and of the client's writer for what its lines
    /// produced for the client, before it stops reading: one maximum line.
    static let readerBacklogBytes = maximumLineBytes
    /// How long the client may take nothing of what waits for it before it
    /// counts as not reading.
    public static let clientStallSeconds: TimeInterval = 30
    /// `log` text that may wait for stderr; later lines are counted and dropped.
    static let logBacklogBytes = 1 << 20
    /// How long `run` lets the client and stderr take what waits for them
    /// once serving stops, and remote connections close.
    static let drainGrace: TimeInterval = 2

    /// How `run` returned.
    public enum Ending: Sendable, Equatable {
        /// The client closed its input, or a shutdown was asked for.
        case finished
        /// The client stopped reading its output: it took nothing of what
        /// waited for it for `clientStallSeconds`.
        case clientNotReading
    }

    /// How a server that went away is started again: its upstream (the
    /// values to scrub) and connection, planned as at serve start.
    public typealias Relaunch = @Sendable (String) -> Result<(MCPGatewayCore.Upstream, MCPUpstreamConnection), MCPLaunchError>

    private var core: MCPGatewayCore
    private let connections: [MCPUpstreamConnection]
    private let relaunch: Relaunch?
    private let oauthStore: MCPOAuthTokenStore
    private let input: Int32
    private let output: Int32
    private let audit: @Sendable (MCPCallRecord) -> Void
    private let event: @Sendable (AuditEvent) -> Void
    private let log: @Sendable (String) -> Void
    private let logRelay: MCPLogRelay
    private let writeBufferBytes: Int
    private let clientStallSeconds: TimeInterval
    /// `MCPGatewayRuntime.stopGrace`, unless a test widens it.
    private let stopGrace: TimeInterval
    /// How long a restart waits for the last process to be reaped:
    /// `stopGrace + restartReapGrace`, unless a test shortens it.
    private let restartWait: TimeInterval
    /// How long serve's own stop leaves each server to exit before SIGTERM:
    /// `MCPPlaceholderShutdown.grace`, unless a test widens it.
    private let shutdownGrace: TimeInterval
    /// `MCPRemoteUpstream.maximumRequestsInFlight`, unless a test lowers it.
    private let remoteRequestLimit: Int
    /// The client's output, written off the gateway queue.
    private let clientWriter: MCPOutbox
    private let clientProgress = MCPWriteProgress()
    /// A list_changed waits for the client, not yet being written: another
    /// adds nothing (the client lists after it either way).
    private let listChangeWaiting = Mutex(false)
    private var clientNotReading = false
    /// A placeholder server is running bound: its name and what its lease staged.
    private let placeholdersBound: @Sendable (String, [SecretDefinition]) -> Void
    private let queue = DispatchQueue(label: "rv.mcp.gateway")
    /// Numbers each launch (a process, or a remote session), so what an old
    /// launch says after it was replaced or stopped reaches nobody.
    private var nextGeneration = 0
    /// The launch of each server the core counts as up: only its lines and
    /// its exit reach the core, and its exit only once.
    private var live: [String: Int] = [:]
    /// Every stdio server's process group not yet reaped (and, for a
    /// placeholder server, its lease not yet revoked), by launch, with the
    /// end a restart waits for.
    private var groups: [Int: (server: String, group: any MCPSupervisedGroup, bound: Bool, ended: MCPLaunchEnd)] = [:]
    /// Each stdio upstream's input, written off the gateway queue.
    private var upstreamWriters: [String: (outbox: MCPOutbox, input: FileHandle)] = [:]
    private var remotes: [String: MCPRemoteUpstream] = [:]
    /// Each remote's sends and its stop, off the gateway queue: a send may
    /// refresh an OAuth token, and a stop waits for its DELETE.
    private var remoteSenders: [String: MCPOutbox] = [:]
    /// Bytes each remote launch has been sent whose POST body has not all
    /// gone out (and whose POST is not over): what waits in the HTTP layer
    /// for the server to take it counts against `writeBufferBytes`.
    private var remoteInFlight: [String: (generation: Int, bytes: Int)] = [:]
    /// Servers whose restart waits for their last process or is being
    /// planned: a restart of one of them, or of a server that is live, is
    /// refused, so a server has at most one launch.
    private var restarting: Set<String> = []
    private let finished = DispatchSemaphore(value: 0)
    private var stopping = false
    /// `stopping`, for restarts off the gateway queue: once it is set, none
    /// plans a launch.
    private let stoppingRestarts = Atomic<Bool>(false)
    /// Feeds the core `.tick` on the gateway queue, so deadlines pass with
    /// no other input.
    private var ticker: DispatchSourceTimer?
    static let tickInterval = DispatchTimeInterval.seconds(1)
    /// How many times `requestShutdown` was called; from the second on,
    /// stopping skips the grace periods.
    private let shutdownRequests = Atomic<Int>(0)

    public init(
        core: MCPGatewayCore,
        connections: [MCPUpstreamConnection],
        oauthStore: MCPOAuthTokenStore = .none,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        writeBufferBytes: Int = MCPGatewayRuntime.writeBufferBytes,
        relaunch: Relaunch? = nil,
        clientStallSeconds: TimeInterval = MCPGatewayRuntime.clientStallSeconds,
        stopGrace: TimeInterval = MCPGatewayRuntime.stopGrace,
        restartWait: TimeInterval? = nil,
        shutdownGrace: TimeInterval? = nil,
        remoteRequestLimit: Int? = nil,
        audit: @escaping @Sendable (MCPCallRecord) -> Void,
        event: @escaping @Sendable (AuditEvent) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void,
        placeholdersBound: @escaping @Sendable (String, [SecretDefinition]) -> Void = { _, _ in }
    ) {
        self.core = core
        self.connections = connections
        self.relaunch = relaunch
        self.oauthStore = oauthStore
        self.input = input
        self.output = output
        self.audit = audit
        self.event = event
        let relay = MCPLogRelay(limit: Self.logBacklogBytes, sink: log)
        self.logRelay = relay
        self.log = { relay.post($0) }
        self.writeBufferBytes = writeBufferBytes
        self.clientStallSeconds = clientStallSeconds
        self.stopGrace = stopGrace
        self.restartWait = restartWait ?? stopGrace + Self.restartReapGrace
        self.shutdownGrace = shutdownGrace ?? MCPPlaceholderShutdown.grace
        self.remoteRequestLimit = remoteRequestLimit ?? MCPRemoteUpstream.maximumRequestsInFlight
        self.clientWriter = MCPOutbox(limit: .max)
        self.placeholdersBound = placeholdersBound
    }

    /// Blocks until the client closes its input, then stops every upstream.
    @discardableResult
    public func run() -> Ending {
        signal(SIGPIPE, SIG_IGN)
        queue.sync {
            var failed: [String] = []
            for connection in connections {
                switch connection {
                case .process(let launch): if spawn(launch) == false { failed.append(launch.server) }
                case .placeholderBound(let launch, let binding):
                    if spawnBound(launch, binding) == false { failed.append(launch.server) }
                case .refused(let server, let refusal):
                    log("not starting MCP server \(server): \(refusal.message)")
                    failed.append(server)
                case .remote(let launch): connect(launch)
                }
            }
            perform(core.start())
            for server in failed { perform(core.handle(.upstreamExited(server: server))) }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [self] in
                guard stopping == false else { return }
                if clientNotReading == false, clientProgress.stalled(after: clientStallSeconds) {
                    clientStopped()
                    return
                }
                perform(core.handle(.tick))
            }
            timer.resume()
            ticker = timer
        }
        let clientInput = input
        Thread.detachNewThread { [self] in
            let backlog = MCPBacklog(limit: Self.readerBacklogBytes)
            Self.readLines(clientInput) { line in
                let message: MCPGatewayInput = (try? JSONValue.parse(line)).map { .client($0) } ?? .clientUnparseable
                backlog.admit(line.count)
                queue.async {
                    // The client is gone for rv, or serving is ending: what
                    // it asks now could not be answered.
                    if self.clientNotReading == false, self.stopping == false {
                        self.perform(self.core.handle(message), charging: backlog)
                    }
                    backlog.release(line.count)
                }
            }
            queue.async { self.finished.signal() }
        }
        finished.wait()
        let ending: Ending = queue.sync {
            stopping = true
            stoppingRestarts.store(true, ordering: .sequentiallyConsistent)
            ticker?.cancel()
            ticker = nil
            perform(core.handle(.gatewayStopping))
            stopUpstreams()
            return clientNotReading ? .clientNotReading : .finished
        }
        // What waits for the client goes out, unless it stopped reading;
        // nothing more is taken.
        clientWriter.close()
        if ending == .finished {
            _ = clientWriter.waitUntilDone(until: Date().addingTimeInterval(hurried ? 0 : Self.drainGrace))
        }
        _ = logRelay.finish(until: Date().addingTimeInterval(hurried ? 0 : Self.drainGrace))
        return ending
    }

    /// `run` stops every upstream and returns, as when the client closes its
    /// input. A second call (a second signal) also cuts the grace short:
    /// every upstream still running is killed now, even mid-shutdown.
    public func requestShutdown() {
        _ = shutdownRequests.add(1, ordering: .sequentiallyConsistent)
        queue.async { self.finished.signal() }
    }

    private var hurried: Bool {
        shutdownRequests.load(ordering: .sequentiallyConsistent) >= 2
    }

    /// A plain server, as the leader of a process group of its own
    /// (`MCPProcessGroup`). Its exit reaches the core when it is reaped.
    private func spawn(_ launch: MCPUpstreamLaunch) -> Bool {
        start(launch, bound: false) { descriptors, exited in
            MCPProcessGroup.spawn(launch, descriptors: descriptors, exited: exited).map { $0 as any MCPSupervisedGroup }
        }
    }

    /// A server with placeholders: started stopped in its own process group,
    /// bound, then resumed (`SecretPlaceholderLease.launch`); on any failure
    /// there it never ran and its lease is gone. Its exit reaches the core
    /// once its group is killed, it is reaped and its lease revoked.
    private func spawnBound(_ launch: MCPUpstreamLaunch, _ binding: MCPPlaceholderBinding) -> Bool {
        let started = start(launch, bound: true) { descriptors, exited in
            do throws(SecretPlaceholderLaunchError) {
                let group = try binding.lease.launch(
                    executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
                    descriptors: descriptors, workingDirectory: launch.workingDirectory, exited: exited)
                return .success(group)
            } catch {
                return .failure(MCPStartFailure(error.message))
            }
        }
        // Not started: its lease ends now (a launch that failed revoked it already).
        guard started else {
            binding.lease.revoke()
            return false
        }
        placeholdersBound(launch.server, binding.lease.definitions)
        return true
    }

    /// Starts one launch of a stdio server through `body` (given the child's
    /// descriptors and what to call once its group is reaped) and reads it.
    /// Its lines and its one exit reach the core while it is `live`.
    private func start(
        _ launch: MCPUpstreamLaunch, bound: Bool,
        _ body: ([Int32: Int32], @escaping @Sendable (Int32) -> Void) -> Result<any MCPSupervisedGroup, MCPStartFailure>
    ) -> Bool {
        let server = launch.server
        let shown = MCPDisplayedText.field(server)
        guard let pipes = MCPPipe.make(3) else {
            log("could not start MCP server \(shown): no pipes")
            return false
        }
        let (stdin, stdout, stderr) = (pipes[0], pipes[1], pipes[2])
        let generation = nextGeneration
        nextGeneration += 1
        let gate = MCPExitGate { [self] in
            queue.async { self.exited(server, generation) }
        }
        let ended = MCPLaunchEnd()
        let started = body(
            [STDIN_FILENO: stdin.read, STDOUT_FILENO: stdout.write, STDERR_FILENO: stderr.write],
            { [self] _ in
                ended.end()
                queue.async { self.groups[generation] = nil }
                gate.reaped()
            })
        // The child holds its own copies of these ends.
        close(stdin.read)
        close(stdout.write)
        close(stderr.write)
        let group: any MCPSupervisedGroup
        switch started {
        case .failure(let reason):
            close(stdin.write)
            close(stdout.read)
            close(stderr.read)
            log("could not start MCP server \(shown): \(reason.reason)")
            return false
        case .success(let running): group = running
        }
        groups[generation] = (server, group, bound, ended)
        live[server] = generation
        upstreamWriters[server] = (MCPOutbox(limit: writeBufferBytes), FileHandle(fileDescriptor: stdin.write, closeOnDealloc: true))
        let stderrReader = stderr.read
        Thread.detachNewThread {
            Self.relayStderr(stderrReader) { data in
                Self.writeStderr(data)
            }
            close(stderrReader)
        }
        let reader = stdout.read
        Thread.detachNewThread { [self] in
            readUpstream(server, reader, generation: generation)
            close(reader)
            // It can answer nothing more: its group is ended (a placeholder
            // server's lease with it), and its exit follows its reap.
            queue.async {
                guard self.stopping == false else { return }
                group.signal(SIGKILL)
            }
            gate.drained()
        }
        return true
    }

    /// One launch is gone. The core hears of it once, and only while that
    /// launch is still the one it counts as up.
    private func exited(_ server: String, _ generation: Int) {
        guard stopping == false, live[server] == generation else { return }
        live[server] = nil
        release(server)
        perform(core.handle(.upstreamExited(server: server)))
    }

    /// Hands each line `server` writes to the gateway queue, waiting while
    /// `readerBacklogBytes` of them are not yet handled. Returns at EOF.
    private func readUpstream(_ server: String, _ fd: Int32, generation: Int) {
        let backlog = MCPBacklog(limit: Self.readerBacklogBytes)
        Self.readLines(fd) { line in
            guard let message = try? JSONValue.parse(line) else {
                log("MCP server \(server) wrote a line that is not JSON; ignored")
                return
            }
            backlog.admit(line.count)
            queue.async {
                if self.live[server] == generation {
                    self.perform(self.core.handle(.upstream(server: server, message: message)), charging: backlog)
                }
                backlog.release(line.count)
            }
        }
    }

    private func connect(_ launch: MCPRemoteLaunch) {
        let server = launch.server
        let generation = nextGeneration
        nextGeneration += 1
        let authorizer = launch.oauth.map { tokens in
            MCPRemoteAuthorizer.oauth(
                server: server, tokens: tokens, store: oauthStore, log: log,
                refreshed: { [self] next in
                    queue.async {
                        for (name, value) in MCPGatewayCore.oauthSecrets(next) {
                            self.core.addSecret(server: server, name: name, value: value)
                        }
                    }
                })
        }
        // Its messages wait, off its delegate queue, while
        // `readerBacklogBytes` of them (and of their output for the client)
        // are not yet handled; its connection goes on reading meanwhile, so
        // past `writeBufferBytes` more waiting there it is stopped.
        let backlog = MCPBacklog(limit: Self.readerBacklogBytes)
        let remote = MCPRemoteUpstream(
            launch: launch, authorizer: authorizer,
            deliver: { [self] message in
                let cost = message.compactText.utf8.count
                backlog.admit(cost)
                queue.async {
                    if self.live[server] == generation {
                        self.perform(self.core.handle(.upstream(server: server, message: message)), charging: backlog)
                    }
                    backlog.release(cost)
                }
            },
            exited: { [self] in
                queue.async { self.exited(server, generation) }
            },
            log: log,
            deliveryLimit: writeBufferBytes,
            overflowed: { [self] in
                queue.async { self.deliveryOverflowed(server, generation) }
            },
            recharge: { [self] cost in
                // A 401 retry's body counts as its first try's did.
                queue.async { self.chargeRemote(server, generation, cost) }
                return { [self] in queue.async { self.chargeRemote(server, generation, -cost) } }
            },
            requestLimit: remoteRequestLimit)
        remotes[server] = remote
        remoteSenders[server] = MCPOutbox(limit: writeBufferBytes)
        remoteInFlight[server] = (generation, 0)
        live[server] = generation
        remote.start()
    }

    /// More than `writeBufferBytes` of what this remote launch sent waits
    /// behind the client's output: it is stopped, which the core hears at
    /// once, and its calls end as on any exit (they may have run).
    private func deliveryOverflowed(_ server: String, _ generation: Int) {
        guard stopping == false, live[server] == generation else { return }
        log("MCP server \(MCPDisplayedText.field(server)) sent more than \(Self.mebibytes(writeBufferBytes)) MiB "
            + "that waits behind the client's output; stopping it")
        stopUpstream(server)
    }

    /// A request this remote launch did not post: the core ends what
    /// waited on it.
    private func unsent(_ server: String, _ generation: Int, id: JSONValue) {
        guard stopping == false, live[server] == generation else { return }
        perform(core.handle(.upstreamUnsent(server: server, id: id)))
    }

    /// Adds `bytes` (or takes them off) to what this remote launch counts
    /// against its bound; a later launch's count is not touched.
    private func chargeRemote(_ server: String, _ generation: Int, _ bytes: Int) {
        guard let now = remoteInFlight[server], now.generation == generation else { return }
        remoteInFlight[server] = (now.generation, now.bytes + bytes)
    }

    /// Test seam: the launch number of `server`'s remote launch.
    func remoteGeneration(_ server: String) -> Int? {
        queue.sync { remoteInFlight[server]?.generation }
    }

    /// Test seam: a report, on the gateway queue, that `server`'s launch
    /// `generation` did not send request `id`.
    func unsentOnQueue(_ server: String, generation: Int, id: JSONValue) {
        queue.sync { unsent(server, generation, id: id) }
    }

    /// Test seam: how many requests `server`'s remote launch has in flight.
    func remoteRequestsInFlight(_ server: String) -> Int? {
        let remote = queue.sync { remotes[server] }
        return remote?.requestsInFlight
    }

    /// Test seam: what `server`'s remote launch counts against its bound now.
    func remoteBytesInFlight(_ server: String) -> Int? {
        queue.sync { remoteInFlight[server]?.bytes }
    }

    /// The core's restart of a server that went away. Off the gateway
    /// queue, every earlier launch of it is waited for until reaped (a
    /// placeholder server's lease revoked), then it is planned again
    /// (`relaunch`, or its serve-start connection); back on the queue it is
    /// started and the core told, or the core hears it went away again.
    /// One asked for while the server is live, or while a restart of it is
    /// under way, is refused and logged: it starts nothing. Once serve is
    /// stopping nothing is planned, and a plan that returns after that is
    /// abandoned (`abandon`).
    private func restart(_ server: String, launch: Int) {
        if let busy = restartRefusal(server) {
            log("not starting MCP server \(MCPDisplayedText.field(server)) again: \(busy)")
            // The core waits for this launch: it hears that it did not
            // start, as one more time the server went away (a launch still
            // running is stopped, which tells it).
            if core.awaitsRelaunch(server: server, launch: launch) {
                if live[server] != nil {
                    stopUpstream(server)
                } else {
                    perform(core.handle(.upstreamExited(server: server)))
                }
            }
            return
        }
        restarting.insert(server)
        let earlier = groups.values.filter { $0.server == server }.map { $0.ended }
        let original = connections.first { $0.server == server }
        let relaunch = relaunch
        let deadline = SuspendingClock.now.advanced(by: .seconds(restartWait))
        Thread.detachNewThread { [self] in
            let planned: Result<(MCPGatewayCore.Upstream?, MCPUpstreamConnection), MCPStartFailure>
            switch MCPLaunchEnd.wait(
                for: earlier, until: deadline, abandoned: { self.stoppingRestarts.load(ordering: .sequentiallyConsistent) })
            {
            case .timedOut: planned = .failure(MCPStartFailure("its last process did not exit"))
            case .abandoned: planned = .failure(MCPStartFailure("serve is stopping"))
            case .ended:
                // From here the launch's start timeout counts.
                queue.async {
                    if self.stopping == false { self.perform(self.core.handle(.upstreamReaped(server: server, launch: launch))) }
                }
                if let relaunch {
                    planned = relaunch(server)
                        .map { pair -> (MCPGatewayCore.Upstream?, MCPUpstreamConnection) in (pair.0, pair.1) }
                        .mapError { MCPStartFailure($0.message) }
                } else {
                    planned = Self.reused(original)
                }
            }
            queue.async { self.relaunched(server, launch: launch, planned) }
        }
    }

    /// Why `server` is not started again now: it is live, or a restart of it
    /// is already under way. Nil when it may be.
    private func restartRefusal(_ server: String) -> String? {
        if live[server] != nil { return "it is running" }
        if restarting.contains(server) { return "it is already being started" }
        return nil
    }

    /// A launch planned while serve stopped: it never starts, so what its
    /// plan started ends now (a placeholder server's lease, a cage's proxy).
    private static func abandon(_ connection: MCPUpstreamConnection) {
        switch connection {
        case .process(let launch): abandonProxy(of: launch)
        case .placeholderBound(let launch, let binding):
            binding.lease.revoke()
            abandonProxy(of: launch)
        case .remote, .refused: break
        }
    }

    private static func abandonProxy(of launch: MCPUpstreamLaunch) {
        if MCPSandbox.proxyCredential(in: launch.environment) != nil { MCPSandbox.stopProxies(server: launch.server) }
    }

    /// How long a restart waits, past `stopGrace`, for the last process to be reaped.
    static let restartReapGrace: TimeInterval = 5

    /// Without `relaunch`: the serve-start connection again, unless it held
    /// a lease, which ended with its process.
    static func reused(_ original: MCPUpstreamConnection?) -> Result<(MCPGatewayCore.Upstream?, MCPUpstreamConnection), MCPStartFailure> {
        guard let original else { return .failure(MCPStartFailure("it has nothing to start")) }
        switch original {
        case .process, .remote: return .success((nil, original))
        case .placeholderBound: return .failure(MCPStartFailure("its placeholders cannot be leased again without planning it again"))
        case .refused: return .failure(MCPStartFailure("it has nothing to start"))
        }
    }

    private func relaunched(
        _ server: String, launch: Int, _ planned: Result<(MCPGatewayCore.Upstream?, MCPUpstreamConnection), MCPStartFailure>
    ) {
        let shown = MCPDisplayedText.field(server)
        restarting.remove(server)
        // Serving ends, or the core stopped waiting for this launch (it ran
        // out of time): nothing is started, what its plan started ends, and
        // the core is not told.
        guard stopping == false, core.awaitsRelaunch(server: server, launch: launch) else {
            if case .success((_, let next)) = planned { Self.abandon(next) }
            return
        }
        let connection: MCPUpstreamConnection
        switch planned {
        case .failure(let reason):
            log("could not start MCP server \(shown) again: \(reason.reason)")
            perform(core.handle(.upstreamExited(server: server)))
            return
        case .success((let upstream, let next)):
            for secret in upstream?.secretValues ?? [] {
                core.addSecret(server: server, name: secret.name, value: secret.value)
            }
            connection = next
        }
        let started: Bool
        switch connection {
        case .process(let launch): started = spawn(launch)
        case .placeholderBound(let launch, let binding): started = spawnBound(launch, binding)
        case .remote(let launch):
            connect(launch)
            started = true
        case .refused(_, let refusal):
            log("not starting MCP server \(shown) again: \(refusal.message)")
            started = false
        }
        // Planned but not spawned: its cage's proxy ends now (a placeholder
        // server's lease ended with the failed start).
        if started == false {
            switch connection {
            case .process(let launch), .placeholderBound(let launch, _): Self.abandonProxy(of: launch)
            case .remote, .refused: break
            }
        }
        perform(core.handle(started ? .upstreamRelaunched(server: server, launch: launch) : .upstreamExited(server: server)))
    }

    /// Runs `outputs` on the gateway queue as if the core had produced them:
    /// for tests that drive the runtime past what the core asks of it.
    func performOnQueue(_ outputs: [MCPGatewayOutput]) {
        queue.sync { perform(outputs) }
    }

    /// `charging`: the reader whose line produced `outputs`, held back until
    /// what they send the client is written. rv's own (deadlines, exits,
    /// restarts) is charged to no reader and always queued.
    private func perform(_ outputs: [MCPGatewayOutput], charging backlog: MCPBacklog? = nil) {
        for item in outputs {
            switch item {
            case .toClient(let message):
                sendToClient(message, charging: backlog)
            case .toUpstream(let server, let message):
                sendUpstream(server, message)
            case .audit(let record):
                audit(record)
            case .event(let item):
                event(item)
            case .log(let text):
                log(text)
            case .stopUpstream(let server):
                stopUpstream(server)
            case .restartUpstream(let server, let launch):
                restart(server, launch: launch)
            }
        }
    }

    /// Queued for the client's writer, its written (escaped) bytes charged
    /// to `backlog` until written. A list_changed is dropped while another
    /// waits.
    private func sendToClient(_ message: JSONValue, charging backlog: MCPBacklog?) {
        guard clientNotReading == false else { return }
        let listChange = message["id"] == nil && message["method"]?.stringValue == "notifications/tools/list_changed"
        if listChange, listChangeWaiting.withLock({ waiting in defer { waiting = true }; return waiting }) { return }
        let bytes = Self.line(message)
        let fd = output
        let progress = clientProgress
        backlog?.charge(bytes.count)
        progress.queued()
        let admission = clientWriter.submit(cost: bytes.count) { [self] in
            if listChange { listChangeWaiting.withLock { $0 = false } }
            Self.writeAll(fd, bytes, wrote: progress.wrote)
            progress.finished()
            backlog?.release(bytes.count)
        }
        if admission != .queued {
            progress.finished()
            backlog?.release(bytes.count)
        }
    }

    /// The client took nothing for `clientStallSeconds`: serving stops, `run`
    /// says why, and nothing more is written.
    private func clientStopped() {
        clientNotReading = true
        clientWriter.abandon()
        log("the MCP client is not reading its output (nothing taken for \(Int(clientStallSeconds)) s); stopping")
        finished.signal()
    }

    /// Queued for the upstream's writer or remote sender. Past its bound the
    /// upstream is not reading: it is stopped, which the core hears at once.
    private func sendUpstream(_ server: String, _ message: JSONValue) {
        let admission: MCPOutbox.Admission
        if let writer = upstreamWriters[server] {
            let bytes = Self.line(message)
            let fd = writer.input.fileDescriptor
            admission = writer.outbox.submit(cost: bytes.count) { Self.writeAll(fd, bytes) }
        } else if let sender = remoteSenders[server], let remote = remotes[server], let flight = remoteInFlight[server] {
            // Counted from here until its body has gone out, not until answered.
            let cost = message.compactText.utf8.count
            if flight.bytes > 0, flight.bytes + cost > writeBufferBytes {
                admission = .overflow
            } else {
                admission = sender.submit(cost: 0) { [self] in
                    let sent = remote.send(message) { [self] in
                        queue.async {
                            guard let now = self.remoteInFlight[server], now.generation == flight.generation else { return }
                            self.remoteInFlight[server] = (now.generation, now.bytes - cost)
                        }
                    }
                    // Not posted (the remote has its most requests in
                    // flight): a request waiting on it ends now.
                    if sent == false, MCPHTTPExchange.isRequest(message), let id = message["id"] {
                        queue.async { self.unsent(server, flight.generation, id: id) }
                    }
                }
                if admission == .queued { remoteInFlight[server] = (flight.generation, flight.bytes + cost) }
            }
        } else {
            return
        }
        guard admission == .overflow else { return }
        log("MCP server \(MCPDisplayedText.field(server)) is not reading its input "
            + "(more than \(Self.mebibytes(writeBufferBytes)) MiB waiting); stopping it")
        stopUpstream(server)
    }

    /// How long a stopped server has between SIGTERM and SIGKILL.
    public static let stopGrace: TimeInterval = 2

    /// Stops this server's process group, or closes its connection, never
    /// waiting on the gateway queue: SIGTERM to the whole group now and
    /// SIGKILL after `stopGrace` if its leader is still there, from a timer
    /// on the queue (a leader that exited has its group killed by its
    /// supervisor); signals reach a group only while its leader is
    /// unreaped. Its input is closed by its writer, and a remote's stop (and
    /// its DELETE) runs on its sender. The core hears it is gone now, once:
    /// its later exit, and anything it still writes, reach nobody.
    private func stopUpstream(_ server: String) {
        for entry in groups.values where entry.server == server {
            let group = entry.group
            group.signal(SIGTERM)
            queue.asyncAfter(deadline: .now() + stopGrace) {
                if group.hasExited == false { group.signal(SIGKILL) }
            }
        }
        let wasLive = live.removeValue(forKey: server) != nil
        release(server)
        if wasLive { perform(core.handle(.upstreamExited(server: server))) }
    }

    /// Closes the server's input (after the write running now) and its
    /// remote connection.
    private func release(_ server: String) {
        if let writer = upstreamWriters.removeValue(forKey: server) {
            let input = writer.input
            writer.outbox.abandon { try? input.close() }
        }
        if let remote = remotes.removeValue(forKey: server) {
            remoteInFlight[server] = nil
            remoteSenders.removeValue(forKey: server)?.abandon { remote.stop() }
        }
    }

    private func stopUpstreams() {
        live = [:]
        // Remote stops (each DELETE waits at most 2 s) run on their senders,
        // side by side, while the processes stop.
        var closing: [MCPOutbox] = []
        for (server, remote) in remotes {
            guard let sender = remoteSenders[server] else { continue }
            sender.close { remote.stop() }
            closing.append(sender)
        }
        remotes = [:]
        remoteSenders = [:]
        remoteInFlight = [:]
        // Each input closes once what is queued for it is written, or once
        // its process is gone below and the write fails.
        for writer in upstreamWriters.values {
            let input = writer.input
            writer.outbox.close { try? input.close() }
        }
        upstreamWriters = [:]
        stopGroups()
        let closed = Date().addingTimeInterval(hurried ? 0 : Self.drainGrace + 1)
        for sender in closing { _ = sender.waitUntilDone(until: closed) }
    }

    /// Signals each server's whole group as `MCPPlaceholderShutdown` says
    /// until its leader exits (its input closed above, it has the grace to
    /// exit on its own), then waits for its supervisor to kill the rest of
    /// the group, reap it and revoke its lease. Bounded: a placeholder group
    /// still there after that is left to the broker's stop, which ends
    /// every lease. Timed on the monotonic clock, so a wall-clock step
    /// neither cuts the graces short nor stretches them.
    private func stopGroups() {
        let origin = SuspendingClock.now
        // Seconds since `origin`, as the Date `MCPPlaceholderShutdown` steps on.
        func elapsed() -> Date {
            let (seconds, attoseconds) = origin.duration(to: SuspendingClock.now).components
            return Date(timeIntervalSinceReferenceDate: TimeInterval(seconds) + TimeInterval(attoseconds) * 1e-18)
        }
        let started = elapsed()
        var shutdowns = groups.mapValues { _ in MCPPlaceholderShutdown(started: started, grace: shutdownGrace) }
        func waiting(_ now: Date) -> Bool {
            groups.contains { launch, entry in
                entry.group.hasExited == false && now < (shutdowns[launch]?.giveUp ?? now)
            }
        }
        while waiting(elapsed()) {
            let now = elapsed()
            let hurry = hurried
            for (launch, entry) in groups {
                let exited = entry.group.hasExited
                let number = hurry
                    ? shutdowns[launch]?.hurry(exited: exited)
                    : shutdowns[launch]?.signal(exited: exited, now: now)
                if let number { entry.group.signal(number) }
            }
            usleep(20_000)
        }
        let reaped = SuspendingClock.now.advanced(by: .seconds(2))
        for entry in groups.values where MCPLaunchEnd.wait(for: [entry.ended], until: reaped, abandoned: { false }) != .ended {
            let shown = MCPDisplayedText.field(entry.server)
            log(entry.bound
                ? "MCP server \(shown) did not exit; its placeholders end when serve stops the secrets gateway"
                : "MCP server \(shown) did not exit; it is left running")
        }
        groups = [:]
    }

    /// Serialized raw-fd stderr write shared by every upstream relay thread.
    /// `FileHandle.write` raises on EPIPE/closed fd, which would crash the
    /// gateway if a child writes after stderr closes; `StderrWriter` just
    /// fails, whatever the SIGPIPE disposition.
    static func writeStderr(_ data: Data) {
        StderrWriter.write(data)
    }

    static func line(_ message: JSONValue) -> [UInt8] {
        Array((message.compactText + "\n").utf8)
    }

    static func mebibytes(_ bytes: Int) -> Int { bytes >> 20 }

    /// The most one `write` is given, so a reader that takes a long line
    /// slowly but steadily is seen to make progress while it does.
    static let writeChunkBytes = 1 << 20

    /// Blocks until every byte is written or the write fails (a reader that
    /// is gone, or any error other than an interrupt): only ever on a
    /// writer's own thread. A non-blocking descriptor that is full is waited
    /// on, so a line is never left half written. `wrote` is told after each
    /// part of `bytes` is written, at most `writeChunkBytes` at a time.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8], wrote: (() -> Void)? = nil) {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + written, min(raw.count - written, writeChunkBytes))
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, -1)
                continue
            }
            guard n > 0 else { return }
            written += n
            wrote?()
        }
    }

    /// Calls `body` for each newline-terminated line (CR stripped). Lines
    /// over the cap are dropped whole. Returns at EOF or on a read error.
    static func readLines(_ fd: Int32, _ body: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var line: [UInt8] = []
        var overflowing = false
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            var start = 0
            for index in 0..<n where buffer[index] == 0x0A {
                if overflowing == false {
                    line += buffer[start..<index]
                    if line.last == 0x0D { line.removeLast() }
                    if line.isEmpty == false { body(Data(line)) }
                }
                line.removeAll(keepingCapacity: true)
                overflowing = false
                start = index + 1
            }
            if overflowing == false {
                line += buffer[start..<n]
                if line.count > maximumLineBytes {
                    overflowing = true
                    line.removeAll()
                }
            }
        }
        if overflowing == false, line.isEmpty == false { body(Data(line)) }
    }

    /// Child stderr is escaped before it reaches the gateway stderr, which is
    /// also where the confirmation code is printed. The child does not share
    /// that file descriptor.
    static func displayedStderr(_ data: Data) -> Data {
        Data(MCPDisplayedText.field(String(decoding: data, as: UTF8.self)).utf8)
    }

    /// Bytes that form complete UTF-8 scalars, and a trailing incomplete
    /// sequence of at most three bytes. A split U+2028 or U+202E is not
    /// escaped until the rest of the scalar arrives.
    static func completeUTF8Prefix(_ data: Data) -> (complete: Data, rest: Data) {
        if data.isEmpty { return (Data(), Data()) }
        let bytes = [UInt8](data)
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0 && continuation < 3 && (bytes[index] & 0xC0) == 0x80 {
            continuation += 1
            index -= 1
        }
        if index < 0 { return (data, Data()) }
        let lead = bytes[index]
        let needed: Int
        if lead < 0x80 {
            needed = 1
        } else if lead & 0xE0 == 0xC0 {
            needed = 2
        } else if lead & 0xF0 == 0xE0 {
            needed = 3
        } else if lead & 0xF8 == 0xF0 {
            needed = 4
        } else {
            needed = 1
        }
        let have = bytes.count - index
        if have < needed {
            return (Data(bytes[..<index]), Data(bytes[index...]))
        }
        return (data, Data())
    }

    /// Read `fd` until EOF and write the escaped bytes. Does not wait for a
    /// newline: a child can clear the screen with no trailing line break.
    static func relayStderr(_ fd: Int32, write: (Data) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            pending.append(contentsOf: buffer.prefix(count))
            let split = completeUTF8Prefix(pending)
            pending = split.rest
            if split.complete.isEmpty == false {
                write(displayedStderr(split.complete))
            }
        }
        if pending.isEmpty == false {
            write(displayedStderr(pending))
        }
    }
}
