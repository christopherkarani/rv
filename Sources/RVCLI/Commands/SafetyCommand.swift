import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

enum SafetyRun {
    static func show(home: HomeDirectory, workspace: URL?) -> String {
        SafetyStore.loadEffective(home: home, workspace: workspace).rawValue
    }

    static func set(_ level: SafetyLevel, home: HomeDirectory) throws {
        try LocalControlBoundary.requireOwnerAuthorization()
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
        let home = try CommandContext.requireHome(command: "safety")
        if let raw = level {
            guard let parsed = SafetyLevel(rawValue: raw) else {
                try CommandContext.fail("rv safety: expected normal or strict\n")
            }
            do {
                try SafetyRun.set(parsed, home: home)
            } catch {
                try CommandContext.fail("rv safety: could not write config\n")
            }
            CommandContext.writeStdout(parsed.rawValue + "\n")
            return
        }
        let workspace = URL(
            fileURLWithPath: CLIProcess.workspacePath(),
            isDirectory: true
        )
        CommandContext.writeStdout(
            SafetyRun.show(home: home, workspace: workspace) + "\n"
        )
    }
}
