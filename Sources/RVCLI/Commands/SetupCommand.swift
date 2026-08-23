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
        guard let env = SetupEnvironment.live() else {
            FileHandle.standardError.write(Data("rv setup: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let resolved = CeremonyCLI.appearance(
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        )
        let outcome = SetupRun.setup(
            env,
            appearance: resolved.appearance,
            ceremonyKind: SetupCeremonyKind.fromInstallEnvironment(),
            force: force,
            clock: LiveSetupCeremonyClock(),
            animate: resolved.animate,
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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SetupCeremonyKind {
        let raw = environment["RV_FROM_INSTALL"] ?? ""
        if raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes" {
            return .install
        }
        return .setup
    }
}
