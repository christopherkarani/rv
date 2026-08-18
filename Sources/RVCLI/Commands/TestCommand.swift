import ArgumentParser
import Foundation

struct FormatFlags: ParsableArguments {
    @Flag(name: .customLong("json"), help: "Robot JSON on stdout.")
    var json = false

    @Flag(name: .customLong("robot"), help: "Robot JSON on stdout.")
    var robot = false

    @Flag(name: .customLong("plain"), help: "Disable browse and color.")
    var plain = false

    @Flag(name: .customLong("no-color"), help: "Disable color.")
    var noColor = false
}

struct Test: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Evaluate a command."
    )

    @Flag(name: .customLong("explain"), help: "Print explain steps.")
    var explain = false

    @OptionGroup
    var format: FormatFlags

    @Argument(parsing: .captureForPassthrough, help: "Command to evaluate.")
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
        let kind: CLIKind = explain ? .testExplain : .test
        let result = CommandRun.run(kind: kind, command: raw, probe: probe, requested: requested)
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        throw ExitCode(result.exitCode)
    }
}
