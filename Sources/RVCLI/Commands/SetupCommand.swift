import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import RVService
import RVTheme

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Wire rv-owned host hooks and the rvd LaunchAgent."
    )

    @Flag(name: .customLong("json"), help: "One line, no circles (same as --robot).")
    var json = false

    @Flag(name: .customLong("robot"), help: "One line, no circles.")
    var robot = false

    @Flag(name: .customLong("plain"), help: "Disable color.")
    var plain = false

    @Flag(name: .customLong("no-color"), help: "Disable color.")
    var noColor = false

    @Flag(name: .customLong("force"), help: "Replace occupied owned hooks (backs up to *.bak).")
    var force = false

    @Flag(name: .customLong("observe"), help: "Log what rv would block instead of blocking (guard.mode observe).")
    var observe = false

    func run() async throws {
        // Step 8B P9: one-click install. `rv setup` only writes rv-owned
        // hooks, the LaunchAgent, and config — it adds oversight and cannot
        // manufacture ALLOW — so it runs without device-owner
        // authentication. The dangerous direction is `rv uninstall` (sheds
        // oversight), which is LA-gated in UninstallCommand. `--observe`
        // over an install that already enforces a wired host sheds
        // oversight too, so that one case asks for the owner first.
        let resolved = CeremonyCLI.appearance(
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        )
        let outcome = await setupOutcome(
            intent: SetupIntent(
                kind: .install,
                force: force,
                appearance: resolved.appearance,
                animate: resolved.animate,
                ceremonyKind: .fromInstallEnvironment(),
                observe: observe
            ),
            clock: LiveSetupCeremonyClock(),
            write: CeremonyCLI.stdoutWriter()
        )
        try CeremonyCLI.emit(outcome)
    }

    /// The setup flow, without emitting: tests assert the outcome fields
    /// directly instead of capturing fds, which deadlocks under parallel
    /// test execution. `SetupFlow` asks for the owner (observe over an
    /// enforcing install) and then runs the blocking flow off the pool.
    func setupOutcome(
        intent: SetupIntent,
        clock: LiveSetupCeremonyClock,
        write: @escaping (String) -> Void,
        flow: SetupFlow = .live(),
        probeService: (HomeDirectory) async -> Bool = Setup.liveServiceProbe,
        authenticate: () async throws -> Void = {
            try await CLIOwnerAuth.requireAuthenticated(reason: "Authenticate to switch rv to observe mode.")
        }
    ) async -> SetupOutcome {
        var outcome = await flow.run(intent, clock: clock, write: write, authenticate: authenticate)
        await appendHookServiceWarningIfNeeded(to: &outcome, probeService: probeService)
        return outcome
    }

    /// Liveness of the service the installed hooks talk to. Only the XPC
    /// door can be probed from the Swift client; Linux hooks reach rvd over
    /// a unix socket this client does not speak, so liveness is unknown
    /// there and "unknown" must not print a false "rvd is down" warning.
    static func liveServiceProbe(home: HomeDirectory) async -> Bool {
        #if canImport(XPC)
        return await ServiceClient.probing(home: home).verifyHookService()
        #else
        return true
        #endif
    }

    /// After a green setup, a wired slot with a dead service blocks or prompts
    /// on every command. Say so on stderr (robot stdout stays parseable) instead of
    /// leaving the user to discover it one blocked command at a time.
    private func appendHookServiceWarningIfNeeded(
        to outcome: inout SetupOutcome,
        probeService: (HomeDirectory) async -> Bool
    ) async {
        guard outcome.exitCode == 0 else { return }
        guard let home = CLIProcess.home() else { return }
        guard hasWiredHosts(home: home) else { return }
        let serviceUp = await probeService(home)
        guard SetupServiceWarning.needed(hasWiredHosts: true, serviceUp: serviceUp) else { return }
        if outcome.stderr.isEmpty == false, outcome.stderr.hasSuffix("\n") == false {
            outcome.stderr += "\n"
        }
        let observing = JudgeRuntime.configuredGuardMode(home: home) == .observe
        outcome.stderr += (observing ? SetupServiceWarning.observeText : SetupServiceWarning.text) + "\n"
    }

    private func hasWiredHosts(home: HomeDirectory) -> Bool {
        let pathEntries = (CLIProcess.environment()["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let snapshot = try? HostAdapterInstallation.inspect(
            paths: OwnedPaths(home: home),
            pathEntries: pathEntries,
            fileManager: .default
        ) else { return false }
        return HookHost.setupSlotOrder.contains { host in
            if case .wired = snapshot.installation(for: host) { return true }
            return false
        }
    }

    static func helpText() -> String {
        HelpDispatch.text(.setup, palette: colorOffPalette)
    }
}

/// Post-setup service warning: hooks without a reachable daemon block or
/// prompt on every command, so a green setup with a down service must say so.
enum SetupServiceWarning {
    static let text =
        "Warning: the RV background service (rvd) is not answering. Installed hooks will block or prompt on every command until it is up. Run `rv doctor`."
    /// Under observe a missing daemon makes hooks step aside instead.
    static let observeText =
        "Warning: the RV background service (rvd) is not answering. In observe mode hooks let commands run unchecked and unlogged while it is down (a slow rvd still prompts). Run `rv doctor`."

    static func needed(hasWiredHosts: Bool, serviceUp: Bool) -> Bool {
        hasWiredHosts && serviceUp == false
    }
}

extension SetupCeremonyKind {
    static func fromInstallEnvironment(
        environment: [String: String] = CLIProcess.environment()
    ) -> SetupCeremonyKind {
        let raw = environment["RV_FROM_INSTALL"] ?? ""
        if raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes" {
            return .install
        }
        return .setup
    }
}
