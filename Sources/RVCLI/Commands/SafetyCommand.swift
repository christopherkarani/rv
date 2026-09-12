import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

enum SafetyRun {
    static func show(home: HomeDirectory, workspace: URL?) -> String {
        SafetyStore.loadEffective(home: home, workspace: workspace).rawValue
    }

    static func set(_ level: SafetyLevel, home: HomeDirectory) throws {
        try SafetyStore(
            configDirectory: RVPolicyPaths.configDirectory(home: home)
        ).saveMachine(level)
    }
}

struct Safety: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safety",
        abstract: "Show or set normal or strict."
    )

    @Argument(help: "normal or strict.")
    var level: String?

    func run() throws {
        guard let home = HomeDirectory.process() else {
            FileHandle.standardError.write(Data("rv safety: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        if let raw = level {
            guard let parsed = SafetyLevel(rawValue: raw) else {
                FileHandle.standardError.write(Data("rv safety: expected normal or strict\n".utf8))
                throw ExitCode(1)
            }
            do {
                try SafetyRun.set(parsed, home: home)
            } catch {
                FileHandle.standardError.write(Data("rv safety: could not write config\n".utf8))
                throw ExitCode(1)
            }
            FileHandle.standardOutput.write(Data((parsed.rawValue + "\n").utf8))
            return
        }
        let workspace = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        FileHandle.standardOutput.write(
            Data((SafetyRun.show(home: home, workspace: workspace) + "\n").utf8)
        )
    }
}
