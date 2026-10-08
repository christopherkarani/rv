import ArgumentParser
import Foundation
import RVPresentation
import RVTheme

struct Setup: ParsableCommand {
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

    func run() throws {
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
        let outcome = SetupFlow.live().run(
            SetupIntent(
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
