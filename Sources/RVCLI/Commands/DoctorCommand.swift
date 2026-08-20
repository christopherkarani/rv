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
        guard let environment = DoctorEnvironment.live() else {
            FileHandle.standardError.write(Data("rv doctor: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let appearance = CLIAppearance.resolve(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        let diagnostics = await ServiceClient().diagnostics()
        let outcome = DoctorRun.run(
            environment: environment,
            diagnostics: diagnostics,
            appearance: appearance
        )
        if outcome.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if outcome.stderr.isEmpty == false {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }
}
