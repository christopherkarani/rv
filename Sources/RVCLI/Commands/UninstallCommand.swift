import ArgumentParser
import Darwin
import Foundation
import RVPresentation
import RVTheme

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove rv-owned hook files, config, and the rvd LaunchAgent."
    )

    @Flag(name: .customLong("json"), help: "One line, no circles (same as --robot).")
    var json = false

    @Flag(name: .customLong("robot"), help: "One line, no circles.")
    var robot = false

    @Flag(name: .customLong("plain"), help: "Disable browse and color.")
    var plain = false

    @Flag(name: .customLong("no-color"), help: "Disable color.")
    var noColor = false

    func run() throws {
        guard let env = SetupEnvironment.live() else {
            FileHandle.standardError.write(Data("rv uninstall: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let appearance = CLIAppearance.resolve(
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        )
        let animate: Bool
        if case .pretty = appearance {
            animate = isatty(STDOUT_FILENO) != 0
        } else {
            animate = false
        }
        let outcome = SetupRun.uninstall(
            env,
            appearance: appearance,
            clock: LiveSetupCeremonyClock(),
            animate: animate,
            write: { chunk in
                FileHandle.standardOutput.write(Data(chunk.utf8))
            }
        )
        if outcome.emitted == false, outcome.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if outcome.stderr.isEmpty == false {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }

    static func helpText() -> String {
        HelpDispatch.text(.uninstall, palette: colorOffPalette)
    }
}
