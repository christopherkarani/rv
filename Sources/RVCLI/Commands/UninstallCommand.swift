import ArgumentParser
import Foundation
import RVTheme

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove rv-owned hook files, config, and the rvd LaunchAgent."
    )

    @Flag(name: .customLong("json"), help: "One line, no circles (same as --robot).")
    var json = false

    @Flag(name: .customLong("robot"), help: "One line, no circles.")
    var robot = false

    @Flag(name: .customLong("plain"), help: "Disable color.")
    var plain = false

    @Flag(name: .customLong("no-color"), help: "Disable color.")
    var noColor = false

    func run() async throws {
        // Uninstall sheds oversight (hooks, config, LaunchAgent): a
        // same-user agent must not run it unattended. One fresh
        // device-owner authentication, then the existing ceremony.
        do {
            try await CLIOwnerAuth.requireAuthenticated()
        } catch {
            let output = setupFailureOutput(.ownerAuthenticationRequired, command: .uninstall)
            try CeremonyCLI.emit(SetupOutcome(
                stdout: "", stderr: output.stderr, exitCode: output.exitCode))
        }
        let resolved = CeremonyCLI.appearance(
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        )
        let outcome = SetupFlow.live().run(
            SetupIntent(
                kind: .uninstall,
                appearance: resolved.appearance,
                animate: resolved.animate
            ),
            clock: LiveSetupCeremonyClock(),
            write: CeremonyCLI.stdoutWriter()
        )
        try CeremonyCLI.emit(outcome)
    }

    static func helpText() -> String {
        HelpDispatch.text(.uninstall, palette: colorOffPalette)
    }
}
