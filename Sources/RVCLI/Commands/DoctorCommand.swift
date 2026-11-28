import ArgumentParser
import Foundation

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Read service, pack, and Host adapter health."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "doctor", format: format)
        guard let outcome = await DoctorRun.collect(
            environment: { DoctorEnvironment.live() },
            client: ServiceClient.probing(home: ctx.home),
            appearance: ctx.appearance
        ) else {
            try ctx.failHomeMissing()
        }
        try ctx.emit(
            stdout: outcome.stdout,
            stderr: outcome.stderr,
            exitCode: outcome.exitCode
        )
    }
}
