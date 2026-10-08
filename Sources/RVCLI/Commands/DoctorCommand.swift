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
        guard let environment = DoctorEnvironment.live() else {
            try ctx.failHomeMissing()
        }
        let diagnostics = await ServiceClient(home: ctx.home).diagnostics()
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: ctx.appearance
        )
        try ctx.emit(
            stdout: outcome.stdout,
            stderr: outcome.stderr,
            exitCode: outcome.exitCode
        )
    }
}
