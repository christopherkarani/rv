import Foundation
import RVPolicy

/// One `rv run`: the secrets to stage and the command to start.
package struct SecretRunRequest: Sendable, Equatable {
    package var secrets: [String]
    package var all: Bool
    /// The command as typed, `command[0]` included.
    package var command: [String]

    package init(secrets: [String], all: Bool, command: [String]) {
        self.secrets = secrets
        self.all = all
        self.command = command
    }
}

/// What `rv run` reads and starts with. Tests point it at a temporary
/// configuration directory and a stand-in resolver.
package struct SecretRunContext: Sendable {
    var configDirectory: URL
    var resolver: SecretResolver
    var transport: SecretUpstreamTransport = .urlSession
    var peers: GatewayPeerCheck = .runtime
    /// Why this host cannot run `rv run` with `peers`, or nil.
    var capability: @Sendable (GatewayPeerCheck) -> SecretRunRefusal? = SecretRunCapability.check
    var environment: [String: String]
    var directory: String
    var manageTerminal: Bool
    /// One stderr line, already prefixed.
    var notice: @Sendable (String) -> Void

    /// `~/.config/rv` from a validated HOME, the live providers, and the
    /// kernel peer check.
    package static func production(
        environment: [String: String], directory: String, notice: @escaping @Sendable (String) -> Void
    ) -> Result<SecretRunContext, SecretRunRefusal> {
        guard let home = HomeDirectory.processValidatedHome(),
            let configDirectory = HomeDirectory.configRoot(for: home)
        else { return .failure(.homeUnavailable) }
        return .success(SecretRunContext(
            configDirectory: configDirectory, resolver: .live(home: home), environment: environment,
            directory: directory, manageTerminal: true, notice: notice))
    }
}

/// Starts a command outside any cage with placeholders in place of the
/// selected secrets, and the gateway honoring them only for that command's
/// process group. Not a sandbox: see `docs/security/secrets-gateway-policy.md`.
package enum SecretRun {
    /// The command's exit code (128 plus the signal that ended it), or why
    /// it never started. The lease is revoked and the gateway stopped on
    /// every path.
    package static func execute(
        _ request: SecretRunRequest, context: SecretRunContext
    ) -> Result<Int32, SecretRunRefusal> {
        guard let name = request.command.first else { return .failure(.emptyCommand) }
        // Before anything is resolved: a launch that cannot be bound must not
        // prompt or unlock. Guarded, so a Ctrl-C cannot end rv while its
        // suspended probe child is alive (it would be left stopped forever).
        let probing = SecretRunSignals()
        let refusal = context.capability(context.peers)
        let interrupted = probing.interrupted
        probing.restore()
        if let refusal { return .failure(refusal) }
        if let interrupted { return .success(SecretRunExit.code(waitStatus: interrupted)) }
        guard let executable = SecretRunCommand.resolve(
            name, path: context.environment["PATH"], directory: context.directory,
            isExecutable: SecretRunCommand.isExecutableFile)
        else { return .failure(.commandNotFound(name)) }
        let configuration: SecretsConfiguration
        switch SecretsConfiguration.load(configDirectory: context.configDirectory) {
        case .failure(let error): return .failure(.configuration(error.message))
        case .success(let loaded): configuration = loaded
        }
        let selection: SecretRunSelection
        switch SecretRunSelection.resolve(configuration, requested: request.secrets, all: request.all) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let resolved): selection = resolved
        }
        for skip in selection.skipped {
            context.notice(
                "rv run: not staging \(skip.name) (\(skip.reason.text)); "
                    + "its variables are removed from the command's environment")
        }

        let broker = SecretLaunchBroker(
            configDirectory: context.configDirectory, resolver: context.resolver, transport: context.transport,
            peers: context.peers, workspace: nil)
        defer { broker.stop() }
        let lease: SecretLease
        switch broker.lease(names: selection.names, agent: nil, placeholdersOnly: true) {
        case .failure(let error): return .failure(.lease(error.message))
        case .success(let leased): lease = leased
        }
        defer { broker.revoke(lease) }
        guard lease.placeholders.isEmpty == false else { return .failure(.lease("no placeholder was staged")) }
        // What is stripped below comes from the lease's definitions: every selected one must be there.
        guard Set(lease.definitions.map(\.name)) == Set(selection.names) else {
            return .failure(.lease("the lease did not stage every selected secret"))
        }

        let environment = SecretRunEnvironment.build(
            parent: context.environment, selected: lease.definitions, skipped: selection.skipped.map(\.definition),
            lease: lease.environment, realValues: lease.realValues)
        // Names the lease replaces with a placeholder go without saying.
        let copies = SecretRunEnvironment.copies(parent: context.environment, realValues: lease.realValues)
            .filter { name in lease.environment.contains { $0.name == name } == false }
        if copies.isEmpty == false {
            context.notice("rv run: removed \(copies.joined(separator: ", ")) from the command's environment: "
                + "each held a selected secret's real value")
        }
        context.notice(
            "rv run: \(selection.names.joined(separator: ", ")) staged as placeholders for this command only. "
                + "Not a sandbox: see `rv help run`.")
        let runtime = "rv-run-" + UUID().uuidString
        let launched = SecretRunProcess.launch(
            executable: executable, arguments: request.command, environment: SecretRunEnvironment.entries(environment),
            manageTerminal: context.manageTerminal
        ) { group in
            broker.bind(lease, runtime: runtime)
            broker.bind(lease, processGroup: group)
            return .success(())
        }
        return launched.map(SecretRunExit.code(waitStatus:))
    }
}
