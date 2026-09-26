import ArgumentParser
import Foundation

struct Service: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Show rvd status.",
        subcommands: [Status.self],
        defaultSubcommand: Status.self
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print whether rvd is running, down, or skewed."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let report = await ServiceClient(home: CLIProcess.home()).status()
        let text = try ServiceStatusCommand.text(
            report,
            appearance: CLIAppearance.resolve(
                json: format.json,
                robot: format.robot,
                plain: format.plain,
                noColor: format.noColor
            )
        )
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
