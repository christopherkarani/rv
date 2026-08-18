import ArgumentParser
import Foundation

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Show why a command is allowed or blocked."
    )

    @OptionGroup
    var format: FormatFlags

    @Argument(parsing: .captureForPassthrough, help: "Command to explain.")
    var commandParts: [String] = []

    func run() throws {
        let raw = commandParts.joined(separator: " ")
        guard !raw.isEmpty else {
            throw ValidationError("missing command")
        }
        let probe = ThemeProbeFactory.live(
            jsonFlag: format.json,
            robotFlag: format.robot,
            plainFlag: format.plain,
            noColorFlag: format.noColor
        )
        let requested = OutputModeResolver.requested(json: format.json, robot: format.robot)
        let result = CommandRun.run(kind: .explain, command: raw, probe: probe, requested: requested)
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        throw ExitCode(result.exitCode)
    }
}
