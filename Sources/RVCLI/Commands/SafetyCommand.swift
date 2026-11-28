import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVService

enum SafetyRun {
    static func show(home: HomeDirectory, workspace: URL?) -> String {
        ManagedGate.effectiveSafety(home: home, workspace: workspace).rawValue
    }

    /// Returns false when the change was filed as a proposal instead (an
    /// agent asking for normal): nothing was written.
    @discardableResult
    static func set(_ level: SafetyLevel, home: HomeDirectory, propose: Bool = false) async throws -> Bool {
        let summary = "set safety to \(level.rawValue)"
        let authorization: String
        if level == .normal {
            // Normal is looser than strict: from an agent, a proposal.
            let route = try await LoosenRoute.ownerOrProposal(
                .safetyNormal, summary: summary, command: "safety", propose: propose)
            guard case .owner(let checked) = route else { return false }
            authorization = checked
        } else {
            authorization = try await OwnerConfirmation.require(summary)
        }
        try await ConfigChangeAudit.$authorization.withValue(authorization) {
            try SafetyStore(
                configDirectory: RVPolicyPaths.configDirectory(home: home)
            ).saveMachine(level)
        }
        return true
    }
}

struct Safety: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safety",
        abstract: "Show or set normal or strict."
    )

    @Argument(help: "normal or strict.")
    var level: String?

    @Flag(name: .customLong("propose"), help: "Send normal to the owner as a proposal; change nothing now.")
    var propose = false

    func run() async throws {
        let home = try CommandContext.requireHome(command: "safety")
        if let raw = level {
            guard let parsed = SafetyLevel(rawValue: raw) else {
                try CommandContext.fail("rv safety: expected normal or strict\n")
            }
            do {
                guard try await SafetyRun.set(parsed, home: home, propose: propose) else { return }
            } catch let refusal as ExitCode {
                // Owner check refused (its line is already on stderr), not
                // "could not write config".
                throw refusal
            } catch let unrecorded as ConfigChangeUnrecorded {
                try ConfigChangeRefusal.fail(command: "safety", unrecorded)
            } catch OwnerConfigWriteError.unreadable {
                try CommandContext.fail(
                    ConfigUnreadableRefusal.message(prefix: "rv safety"), exitCode: ConfigUnreadableRefusal.exitCode)
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
