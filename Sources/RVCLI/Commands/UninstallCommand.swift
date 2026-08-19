import ArgumentParser
import Foundation

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove rv-owned hook files, config, and the rvd LaunchAgent."
    )

    func run() throws {
        guard let env = SetupEnvironment.live() else {
            FileHandle.standardError.write(Data("rv uninstall: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let outcome = SetupRun.uninstall(env)
        if outcome.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if outcome.stderr.isEmpty == false {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }
}
