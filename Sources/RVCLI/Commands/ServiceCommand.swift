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
        let ctx = CommandContext.current(command: "service status", format: format)
        let report = await ServiceClient(home: ctx.home).status()
        let text = try ServiceStatusCommand.text(
            report,
            appearance: ctx.appearance
        )
        ctx.writeStdout(text + "\n")
    }
}
