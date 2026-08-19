import ArgumentParser
import Foundation
import RVTheme

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Wire rv-owned host hooks and the rvd LaunchAgent."
    )

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        guard let env = SetupEnvironment.live() else {
            FileHandle.standardError.write(Data("rv setup: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let probe = ThemeProbeFactory.live(
            jsonFlag: format.json,
            robotFlag: format.robot,
            plainFlag: format.plain,
            noColorFlag: format.noColor
        )
        let requested = OutputModeResolver.requested(json: format.json, robot: format.robot)
        let mode = OutputMode(probe: probe, requested: requested)
        let appearance: SetupAppearance
        switch mode {
        case .robot:
            appearance = .robot
        case .pretty, .browse:
            appearance = .pretty(Palette(for: ColorCapability(probe: probe, mode: mode)))
        }
        let outcome = SetupRun.setup(env, appearance: appearance)
        if outcome.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if outcome.stderr.isEmpty == false {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }
}
