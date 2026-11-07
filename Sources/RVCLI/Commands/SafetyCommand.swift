import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVService

enum SafetyRun {
    static func show(home: HomeDirectory, workspace: URL?) -> String {
        ManagedGate.effectiveSafety(home: home, workspace: workspace).rawValue
    }

    static func set(_ level: SafetyLevel, home: HomeDirectory) async throws {
        try await OwnerConfirmation.require("set safety to \(level.rawValue)")
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

    func run() async throws {
        let home = try CommandContext.requireHome(command: "safety")
        if let raw = level {
            guard let parsed = SafetyLevel(rawValue: raw) else {
                try CommandContext.fail("rv safety: expected normal or strict\n")
            }
            do {
                try await SafetyRun.set(parsed, home: home)
            } catch let refusal as ValidationError {
                // Owner check refused: say why, not "could not write config".
                try CommandContext.fail("\(refusal.message)\n")
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
