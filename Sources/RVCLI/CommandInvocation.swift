import ArgumentParser
import Foundation
import RVPolicy

enum CommandInvocation {
    static func emit(kind: CLIKind, commandParts: [String], format: FormatFlags) async throws {
        let raw = commandParts.joined(separator: " ")
        guard !raw.isEmpty else {
            throw ValidationError("missing command")
        }
        let ctx = CommandContext.current(
            command: kind == .explain ? "explain" : "test",
            format: format
        )
        let result = try await CommandRun.run(
            kind: kind,
            command: raw,
            probe: ctx.probe,
            requested: ctx.requested,
            cwd: FileManager.default.currentDirectoryPath,
            store: allowOnceStore(home: ctx.home),
            home: ctx.home
        )
        try ctx.emit(stdout: result.stdout, exitCode: result.exitCode)
    }

    static func allowOnceStore(home: HomeDirectory?) -> AllowOnceStore {
        if let home {
            return AllowOnceStore.makeLive(home: home)
        }
        return AllowOnceStore(baseDirectory: uniqueEphemeralAllowOnceDirectory())
    }
}

private func uniqueEphemeralAllowOnceDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-\(UUID().uuidString)", isDirectory: true)
}
