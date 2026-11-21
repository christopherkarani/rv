import ArgumentParser
import Foundation
import RVTheme

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove rv's hooks, the rvd service and rv's binaries. Your secrets, MCP state and audit log stay unless --purge."
    )

    @Flag(name: .customLong("json"), help: "One line, no circles (same as --robot).")
    var json = false

    @Flag(name: .customLong("robot"), help: "One line, no circles.")
    var robot = false

    @Flag(name: .customLong("plain"), help: "Disable color.")
    var plain = false

    @Flag(name: .customLong("no-color"), help: "Disable color.")
    var noColor = false

    @Flag(name: .customLong("remove-models"), help: "Also delete the downloaded judge weights (~/.config/rv/models).")
    var removeModels = false

    @Flag(
        name: .customLong("purge"),
        help: "Also delete rv's data: the secret values it stored, ~/.config/rv (secrets, MCP state, audit log, judge weights), its logs and caches."
    )
    var purge = false

    func run() async throws {
        // Uninstall sheds oversight (hooks, config, LaunchAgent): a
        // same-user agent must not run it unattended. One fresh
        // device-owner authentication, then the existing ceremony. With rvd
        // down, a local TTY-only confirmation stands in so the human is
        // never locked out of removing rv (DaemonDownOwnerConfirmation).
        do {
            try await CLIOwnerAuth.requireAuthenticatedOrLocalWhenDaemonDown(
                reason: purge
                    ? "Authenticate to uninstall rv and delete its data and the secret values it stored."
                    : "Authenticate to uninstall rv (removes its hooks, config and background service).",
                action: .uninstall)
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
                animate: resolved.animate,
                removeModels: removeModels,
                purge: purge
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
