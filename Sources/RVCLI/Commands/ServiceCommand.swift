import ArgumentParser
import Foundation

struct Service: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Show rvd status or restart it.",
        subcommands: [Status.self, Restart.self],
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
        let report = await ServiceClient.probing(home: ctx.home).status()
        let text = try ServiceStatusCommand.text(
            report,
            appearance: ctx.appearance
        )
        ctx.writeStdout(text + "\n")
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart rvd: launchctl kickstart -k, or reload the LaunchAgent when it is not loaded."
    )

    func run() throws {
        guard let env = SetupEnvironment.live() else {
            CommandContext.writeStderr(CommandContext.homeMissingText(command: "service restart"))
            throw ExitCode(1)
        }
        try CeremonyCLI.emit(ServiceRestart.run(env))
    }
}
