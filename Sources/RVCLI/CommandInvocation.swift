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
        let home = HomeDirectory.process()
        let result = await CommandRun.run(
            kind: kind,
            command: raw,
            probe: probe,
            requested: requested,
            cwd: FileManager.default.currentDirectoryPath,
            store: allowOnceStore(home: home),
            home: home
        )
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        throw ExitCode(result.exitCode)
    }

    static func allowOnceStore(home: HomeDirectory?) -> AllowOnceStore {
        if let home {
            return AllowOnceStore.live(home: home)
        }
        return AllowOnceStore(baseDirectory: uniqueEphemeralAllowOnceDirectory())
    }
}

private func uniqueEphemeralAllowOnceDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-\(UUID().uuidString)", isDirectory: true)
}
