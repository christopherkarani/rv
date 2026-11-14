#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Placeholders for a process rv starts itself outside `rv run`: a stdio MCP
/// server. The same lease, gateway and process-group binding as `rv run`
/// (`SecretRun`): the process gets placeholders and base URLs, never the
/// real values, and the gateway honors them only for its process group.
package final class SecretPlaceholderBroker: Sendable {
    let broker: SecretLaunchBroker
    private let peers: GatewayPeerCheck

    package convenience init(
        configDirectory: URL, resolver: SecretResolver, transport: SecretUpstreamTransport = .urlSession
    ) {
        self.init(configDirectory: configDirectory, resolver: resolver, transport: transport, peers: .runtime)
    }

    init(configDirectory: URL, resolver: SecretResolver, transport: SecretUpstreamTransport, peers: GatewayPeerCheck) {
        broker = SecretLaunchBroker(
            configDirectory: configDirectory, resolver: resolver, transport: transport, peers: peers, workspace: nil)
        self.peers = peers
    }

    /// Why a lease cannot be bound to a spawned process group on this host,
    /// or nil. Spawns a suspended probe child (`SecretRunCapability`), so it
    /// is asked before any secret is resolved.
    package func capabilityRefusal() -> String? {
        SecretRunCapability.check(peers)?.message
    }

    /// The `runtime` a server's staged and gateway audit records carry.
    package static func runtime(server: String) -> String {
        "mcp:" + server
    }

    /// Placeholders for `names`, staged for `server`. Only `gateway` and
    /// `awsSigV4` secrets with no agent filter stage (as for `rv run`);
    /// anything else, an incomplete lease, a secret with `approve` rules
    /// (no approver can answer for this process) or one read from rv's own
    /// environment stages nothing.
    package func lease(_ names: [String], server: String) -> Result<SecretPlaceholderLease, SecretPlaceholderLeaseError> {
        guard names.isEmpty == false else { return .failure(.noSecretsListed) }
        let leased: SecretLease
        switch broker.lease(names: names, agent: nil, placeholdersOnly: true, runtime: Self.runtime(server: server)) {
        case .failure(let error): return .failure(.refused(error.message))
        case .success(let lease): leased = lease
        }
        guard let port = broker.gatewayPort else {
            broker.revoke(leased)
            return .failure(.gatewayUnavailable)
        }
        if let refusal = Self.refusal(staged: leased.definitions, placeholders: leased.placeholders.count, requested: names) {
            broker.revoke(leased)
            return .failure(refusal)
        }
        return .success(SecretPlaceholderLease(broker: broker, lease: leased, gatewayPort: port))
    }

    /// Why a lease that was staged cannot be used, judged on the definitions
    /// the lease itself loaded: it must hold exactly the requested secrets,
    /// one placeholder each; none may have `approve` rules or come from
    /// rv's own environment.
    static func refusal(
        staged: [SecretDefinition], placeholders: Int, requested: [String]
    ) -> SecretPlaceholderLeaseError? {
        guard Set(staged.map(\.name)) == Set(requested), placeholders == staged.count, staged.isEmpty == false else {
            return .incomplete
        }
        for definition in staged {
            if hasApprovalRules(definition) { return .approvalRules(definition.name) }
            if isHostEnvironmentSourced(definition) { return .hostEnvironmentSource(definition.name) }
        }
        return nil
    }

    /// Read from the environment rv itself was started with. `rv mcp serve`
    /// is started by an MCP client that also starts the servers, so the
    /// value is in the environment of a process outside rv's control.
    package static func isHostEnvironmentSourced(_ definition: SecretDefinition) -> Bool {
        switch definition.source {
        case .hostEnvironment: true
        case .keychain, .onePassword, .vault, .awsSecretsManager, .infisical, .bitwarden, .gcp, .azure, .awsProfile,
            .oauth:
            false
        }
    }

    package static func hasApprovalRules(_ definition: SecretDefinition) -> Bool {
        switch definition.delivery {
        case .gateway(let binding): binding.approvalRules.isEmpty == false
        case .awsSigV4(let binding): binding.approvalRules.isEmpty == false
        case .environment: false
        }
    }

    /// Stops the gateway: every lease ends.
    package func stop() {
        broker.stop()
    }
}

package enum SecretPlaceholderLeaseError: Error, Sendable, Equatable {
    case noSecretsListed
    case gatewayUnavailable
    /// The broker refused; its reason never quotes a value.
    case refused(String)
    case incomplete
    case approvalRules(String)
    case hostEnvironmentSource(String)

    package var message: String {
        switch self {
        case .noSecretsListed: "no placeholder was listed"
        case .gatewayUnavailable: "the secrets gateway is not running"
        case .refused(let reason): reason
        case .incomplete: "the lease did not stage every listed secret as a placeholder"
        case .approvalRules(let name):
            "secret \(name) has approve rules, and no approver can answer for this process; "
                + "remove them or use the secret from a workspace"
        case .hostEnvironmentSource(let name):
            "secret \(name) is read from rv's own environment, which the MCP client that started rv also "
                + "holds; store it in a secret store (keychain, 1Password, ...) instead"
        }
    }
}

package enum SecretPlaceholderLaunchError: Error, Sendable, Equatable {
    case unsupported
    case spawnFailed(String)
    case groupUnreadable
    case resumeFailed

    package var message: String {
        switch self {
        case .unsupported: "this platform cannot start a process suspended until its placeholders are bound"
        case .spawnFailed(let reason): reason
        case .groupUnreadable: "its process group could not be read, so it was stopped before it ran"
        case .resumeFailed: "it could not be resumed after its placeholders were bound, so it was stopped"
        }
    }
}

/// One process's placeholders. Until `launch` binds it to a process group
/// the gateway refuses every one of them (`runtimeUnverified`).
package final class SecretPlaceholderLease: Sendable {
    private let broker: SecretLaunchBroker
    private let lease: SecretLease
    /// Placeholders, base URLs, and the AWS stand-ins, for the environment.
    package let environment: [(name: String, value: String)]
    /// The gateway's loopback port, which the process must be able to dial.
    package let gatewayPort: Int

    init(broker: SecretLaunchBroker, lease: SecretLease, gatewayPort: Int) {
        self.broker = broker
        self.lease = lease
        self.environment = lease.environment
        self.gatewayPort = gatewayPort
    }

    /// The definitions this lease staged, as it loaded them.
    package var definitions: [SecretDefinition] {
        lease.definitions
    }

    /// The gateway refuses these placeholders from now on. Revoking twice is harmless.
    package func revoke() {
        broker.revoke(lease)
    }

    /// Whether a launch with `environment` and `arguments` would hand the
    /// process a real value of this lease after all, by any variable name
    /// or in an argument.
    package func holdsRealValue(environment: [String: String], arguments: [String]) -> Bool {
        Self.holdsRealValue(environment: environment, arguments: arguments, realValues: lease.realValues)
    }

    /// `SecretValueCopy` over each variable's value and each argument.
    static func holdsRealValue(environment: [String: String], arguments: [String], realValues: [SecretValue]) -> Bool {
        guard realValues.isEmpty == false else { return false }
        return (Array(environment.values) + arguments).contains { SecretValueCopy.found(in: $0, realValues: realValues) }
    }

    /// Spawns `executable` stopped as the leader of a new process group,
    /// binds this lease to that group, and resumes it: the image runs no
    /// instruction before the bind. Only `descriptors` (child fd: rv fd) are
    /// inherited. On any failure the child is killed and reaped before it
    /// ran, the lease is revoked, and nothing is returned. `exited` gets the
    /// leader's wait status after the group is killed, the leader reaped and
    /// the lease revoked.
    package func launch(
        executable: String, arguments: [String], environment: [String: String], descriptors: [Int32: Int32],
        workingDirectory: String?, exited: @escaping @Sendable (Int32) -> Void
    ) throws(SecretPlaceholderLaunchError) -> SecretPlaceholderGroup {
        try launch(
            executable: executable, arguments: arguments, environment: environment, descriptors: descriptors,
            workingDirectory: workingDirectory, capture: { ProcessGroupRecovery.capture(pid: $0) }, exited: exited)
    }

    func launch(
        executable: String, arguments: [String], environment: [String: String], descriptors: [Int32: Int32],
        workingDirectory: String?, capture: (pid_t) -> ProcessGroupFact?, exited: @escaping @Sendable (Int32) -> Void
    ) throws(SecretPlaceholderLaunchError) -> SecretPlaceholderGroup {
        #if os(macOS)
        let pid: pid_t
        switch SecretRunProcess.spawnSuspended(
            executable: executable, arguments: [executable] + arguments,
            environment: SecretRunEnvironment.entries(environment), descriptors: descriptors,
            workingDirectory: workingDirectory)
        {
        case .failure(let refusal):
            revoke()
            throw SecretPlaceholderLaunchError.spawnFailed(refusal.message)
        case .success(let spawned): pid = spawned
        }
        guard let group = capture(pid) else {
            SecretRunProcess.discard(pid)
            revoke()
            throw SecretPlaceholderLaunchError.groupUnreadable
        }
        broker.bind(lease, processGroup: group)
        guard kill(pid, SIGCONT) == 0 else {
            SecretRunProcess.discard(pid)
            revoke()
            throw SecretPlaceholderLaunchError.resumeFailed
        }
        let running = SecretPlaceholderGroup(leader: pid)
        running.supervise(revoking: self, exited: exited)
        return running
        #else
        revoke()
        throw SecretPlaceholderLaunchError.unsupported
        #endif
    }
}

/// A running placeholder-bound process group. Its one supervising thread,
/// started at launch, is the only code that reaps: it waits for the leader
/// to exit, kills what is left of the group, reaps the leader and revokes
/// the lease, in that order, as `rv run` does. Anything else may only
/// signal the group, and only before that reap: until then the unreaped
/// leader keeps its group id from being reused.
package final class SecretPlaceholderGroup: Sendable {
    enum Phase: Sendable, Equatable {
        case running
        /// The leader exited and is not reaped yet.
        case exited
        /// Reaped, or no longer this process's child: never signalled again.
        case reaped
        /// Reaped and its lease revoked.
        case finished
    }

    package let leader: pid_t
    private let phase = Mutex(Phase.running)

    init(leader: pid_t) {
        self.leader = leader
    }

    /// Signals the whole group, unless the leader has been reaped.
    package func signal(_ number: Int32) {
        phase.withLock { phase in
            guard phase == .running || phase == .exited else { return }
            _ = kill(-leader, number)
        }
    }

    /// The leader has exited, reaped or not.
    package var hasExited: Bool {
        phase.withLock { $0 != .running }
    }

    /// Polls until the leader is reaped and the lease revoked; false at `deadline`.
    package func waitUntilFinished(until deadline: Date) -> Bool {
        while phase.withLock({ $0 }) != .finished {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    #if os(macOS)
    fileprivate func supervise(revoking lease: SecretPlaceholderLease, exited: @escaping @Sendable (Int32) -> Void) {
        Thread.detachNewThread { [self] in
            let status = waitThenReap()
            lease.revoke()
            phase.withLock { $0 = .finished }
            exited(status)
        }
    }

    private func waitThenReap() -> Int32 {
        var info = siginfo_t()
        // WNOWAIT: the exit is only observed here; the leader is reaped below, after the group kill.
        while waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT) != 0 {
            guard errno == EINTR else {
                // Not our unreaped child any more: its group id may be someone else's.
                phase.withLock { $0 = .reaped }
                return SIGKILL
            }
        }
        phase.withLock { phase in
            phase = .exited
            _ = kill(-leader, SIGKILL)
        }
        return phase.withLock { phase in
            var status: Int32 = 0
            while waitpid(leader, &status, 0) < 0 {
                // Unreapable: report it as killed rather than as success.
                guard errno == EINTR else {
                    status = SIGKILL
                    break
                }
            }
            phase = .reaped
            return status
        }
    }
    #endif
}
