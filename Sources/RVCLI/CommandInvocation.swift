import ArgumentParser
import Foundation
import RVPolicy

enum CommandInvocation {
    static func emit(kind: CLIKind, commandParts: [String], format: FormatFlags) async throws {
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
        let result = await CommandRun.run(
            kind: kind,
            command: raw,
            probe: probe,
            requested: requested,
            cwd: FileManager.default.currentDirectoryPath,
            store: AllowOnceStore.live()
        )
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        throw ExitCode(result.exitCode)
    }
}
