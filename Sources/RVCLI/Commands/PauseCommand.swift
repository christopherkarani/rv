import ArgumentParser
import Foundation

/// `rv pause 10m`: watch instead of block for a while, with Touch ID, and
/// come back on its own. `PauseRun` holds the logic.
struct PauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause rv for up to an hour with Touch ID; it comes back on its own."
    )

    @Argument(help: "How long: 10m, 30m or 1h (at most 1h). Without it, shows whether rv is paused.")
    var duration: String?

    @Flag(name: .customLong("end"), help: "Come back now (no Touch ID needed).")
    var end = false

    @OptionGroup
    var format: FormatFlags

    func validate() throws {
        if end, duration != nil {
            throw ValidationError("give a duration or --end, not both")
        }
        if let duration, PauseRun.duration(duration) == nil {
            throw ValidationError("expected a duration from 1m to 1h, such as 10m")
        }
    }

    func run() async throws {
        guard let env = SetupEnvironment.live() else {
            try CommandContext.failHomeMissing(command: "pause")
        }
        if end {
            try CeremonyCLI.emit(PauseRun.end(env, json: format.json || format.robot))
        }
        guard let duration, let seconds = PauseRun.duration(duration) else {
            try CeremonyCLI.emit(PauseRun.status(env, json: format.json || format.robot))
        }
        // The owner check is the gate: an agent has no finger and does not
        // know the password, and without a terminal it is never prompted.
        try CeremonyCLI.emit(await PauseRun.pause(
            for: seconds, env: env, requester: .live(),
            authenticate: { summary in
                #if canImport(LocalAuthentication)
                CommandContext.writeStderr("  Touch ID to pause …\n")
                #endif
                return try await CLIOwnerAuth.requireAuthenticated(reason: "Authenticate to \(summary).")
            }))
    }
}
