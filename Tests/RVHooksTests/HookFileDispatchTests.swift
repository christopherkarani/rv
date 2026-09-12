import Foundation
import Testing
import RVDomain
@testable import RVHooks

private final class EvaluateProbe: @unchecked Sendable {
    private(set) var commands: [String] = []
    private(set) var files: [String] = []

    func evaluate(_ command: ShellCommand, _: WorkingDirectory?) -> EvaluationResult {
        commands.append(command.rawValue)
        return EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                ),
                matched: nil
            )
        )
    }

    func evaluateFile(_ action: FileToolAction, _: WorkingDirectory?) -> EvaluationResult {
        files.append(action.path.rawValue)
        if action.path.isEmpty {
            Issue.record("evaluateFile should not run for empty path")
        }
        if let rule = SecretPathCatalog.dayOne.firstMatch(of: action.path.rawValue) {
            let ruleID = RuleID(pack: .coreSecrets, pattern: rule.pattern)
            let matched = RuleMatch(
                ruleID: ruleID,
                packID: .coreSecrets,
                patternName: rule.pattern,
                severity: .high,
                reason: rule.reason
            )
            return EvaluationResult(
                outcome: .deny(
                    Deny(ruleID: ruleID, reason: rule.reason),
                    matched: matched
                )
            )
        }
        return EvaluationResult(outcome: .plain)
    }
}

@Test func hookDispatch_fileToolDoesNotCallPackEvaluate() async {
    let probe = EvaluateProbe()
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/.env"}}
    """
    let wire = await hookWire(
        host: .claude,
        stdin: stdin,
        evaluate: { command, cwd in probe.evaluate(command, cwd) },
        evaluateFile: { action, cwd in probe.evaluateFile(action, cwd) }
    )
    #expect(probe.commands.isEmpty)
    #expect(probe.files == ["/tmp/rv-oracle/.env"])
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("core.secrets"))
}

@Test func hookDispatch_emptyFilePathDeniesWithoutEvaluate() async {
    let probe = EvaluateProbe()
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}
    """
    let wire = await hookWire(
        host: .claude,
        stdin: stdin,
        evaluate: { command, cwd in probe.evaluate(command, cwd) },
        evaluateFile: { action, cwd in probe.evaluateFile(action, cwd) }
    )
    #expect(probe.commands.isEmpty)
    #expect(probe.files.isEmpty)
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("no command text"))
}

@Test func hookDispatch_shellResetHardStillEvaluates() async {
    let probe = EvaluateProbe()
    let stdin = """
    {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
    """
    let wire = await hookWire(
        host: .grok,
        stdin: stdin,
        evaluate: { command, cwd in probe.evaluate(command, cwd) },
        evaluateFile: { action, cwd in probe.evaluateFile(action, cwd) }
    )
    #expect(probe.commands == ["git reset --hard"])
    #expect(probe.files.isEmpty)
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
}
