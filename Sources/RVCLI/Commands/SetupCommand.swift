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

    /// The setup flow, without emitting: tests assert the outcome fields
    /// directly instead of capturing fds, which deadlocks under parallel
    /// test execution. The flow proves rvd answers before wiring hooks and
    /// that wait blocks, so it runs on its own thread, never parking a
    /// cooperative-pool thread the readiness probe itself needs.
    func setupOutcome(
        intent: SetupIntent,
        clock: LiveSetupCeremonyClock,
        write: @escaping (String) -> Void,
        flow: SetupFlow = .live()
    ) async -> SetupOutcome {
        nonisolated(unsafe) let flow = flow
        nonisolated(unsafe) let write = write
        // A task-local does not cross into a Thread: carry the test seam over.
        let context = CLIProcess.context
        return await withCheckedContinuation { continuation in
            Thread {
                let outcome = CLIProcess.$context.withValue(context) {
                    flow.run(intent, clock: clock, write: write)
                }
                continuation.resume(returning: outcome)
            }.start()
        }
    }

    static func helpText() -> String {
        HelpDispatch.text(.setup, palette: colorOffPalette)
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
