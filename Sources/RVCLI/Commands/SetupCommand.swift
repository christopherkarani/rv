import ArgumentParser
import Foundation
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

    @Flag(name: .customLong("plain"), help: "Disable browse and color.")
    var plain = false

    @Flag(name: .customLong("no-color"), help: "Disable color.")
    var noColor = false

    func run() throws {
        guard let env = SetupEnvironment.live() else {
            FileHandle.standardError.write(Data("rv setup: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let probe = ThemeProbeFactory.live(
            jsonFlag: json,
            robotFlag: robot,
            plainFlag: plain,
            noColorFlag: noColor
        )
        let requested = OutputModeResolver.requested(json: json, robot: robot)
        let mode = OutputMode(probe: probe, requested: requested)
        let appearance = SetupAppearance.resolved(
            mode: mode,
            ci: probe.ci,
            palette: Palette(for: ColorCapability(probe: probe, mode: mode))
        )
        let outcome = SetupRun.setup(env, appearance: appearance)
        if outcome.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if outcome.stderr.isEmpty == false {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }

    static func helpText() -> String {
        helpMessage(columns: 100)
    }
}
