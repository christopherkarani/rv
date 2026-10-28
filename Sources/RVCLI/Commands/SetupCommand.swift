import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVPresentation
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

    func run() async throws {
        // Step 8B P9: one-click install. `rv setup` only writes rv-owned
        // hooks, the LaunchAgent, and config — it adds oversight and cannot
        // manufacture ALLOW — so it runs without device-owner
        // authentication. The dangerous direction is `rv uninstall` (sheds
        // oversight), which is LA-gated in UninstallCommand.
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
                ceremonyKind: .fromInstallEnvironment()
            ),
            clock: LiveSetupCeremonyClock(),
            write: CeremonyCLI.stdoutWriter()
        )
        try CeremonyCLI.emit(outcome)
    }

    /// Setup flow plus the post-setup service warning, without emitting:
    /// tests assert the outcome fields directly instead of capturing fds,
    /// which deadlocks under parallel test execution.
    func setupOutcome(
        intent: SetupIntent,
        clock: LiveSetupCeremonyClock,
        write: @escaping (String) -> Void
    ) async -> SetupOutcome {
        var outcome = SetupFlow.live().run(intent, clock: clock, write: write)
        await appendHookServiceWarningIfNeeded(to: &outcome)
        return outcome
    }

    /// After a green setup, a wired slot with a dead service denies every
    /// command. Say so on stderr (robot stdout stays parseable) instead of
    /// leaving the user to discover it one blocked command at a time.
    private func appendHookServiceWarningIfNeeded(to outcome: inout SetupOutcome) async {
        guard outcome.exitCode == 0 else { return }
        guard let home = CLIProcess.home() else { return }
        guard hasWiredHosts(home: home) else { return }
        let serviceUp = await ServiceClient(home: home).verifyHookService()
        guard SetupServiceWarning.needed(hasWiredHosts: true, serviceUp: serviceUp) else { return }
        if outcome.stderr.isEmpty == false, outcome.stderr.hasSuffix("\n") == false {
            outcome.stderr += "\n"
        }
        outcome.stderr += SetupServiceWarning.text + "\n"
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

/// Post-setup service warning: hooks without a reachable daemon deny
/// every command, so a green setup with a down service must say so.
enum SetupServiceWarning {
    static let text =
        "Warning: the RV background service (rvd) is not answering. Installed hooks will deny every command until it is up. Run `rv doctor`."

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
