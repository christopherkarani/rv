import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Test func hookWire_denyAddsRuleAndNextWithoutBreakingDecisionReason() throws {
    let result = EvaluationResult(
        decision: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
        )
    )
    let wire = hookWire(
        from: result,
        command: ShellCommand(rawValue: "git reset --hard"),
        using: GrokHostCodec()
    )
    let object = try JSONSerialization.jsonObject(with: Data(wire.stdout.utf8))
    let json = try #require(object as? [String: Any])
    #expect(json["decision"] as? String == "deny")
    #expect(
        json["reason"] as? String
            == "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    )
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(json["next"] as? String == hookUnlockNext)
    #expect(wire.exitCode == 0)
}

@Test func hookWire_allowIsEmpty() {
    let wire = hookWire(
        from: EvaluationResult(decision: .allow),
        command: ShellCommand(rawValue: "git status"),
        using: GrokHostCodec()
    )
    #expect(wire.stdout.isEmpty)
    #expect(wire.exitCode == 0)
}

@Test func hookWire_indeterminateOmitsRule() throws {
    let wire = hookWire(
        from: EvaluationResult(decision: .indeterminate(.commandTooLarge)),
        command: ShellCommand(rawValue: "x"),
        using: GrokHostCodec()
    )
    let object = try JSONSerialization.jsonObject(with: Data(wire.stdout.utf8))
    let json = try #require(object as? [String: Any])
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == incompleteEvalSentence)
    #expect(json["rule"] == nil)
    #expect(json["next"] == nil)
}

@Test func grokDecode_readsCwdWhenPresent() throws {
    let stdin = """
    {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git status"}}
    """
    let request = GrokHostCodec().decode(stdin)
    #expect(request.command?.rawValue == "git status")
    #expect(request.cwd == "/tmp/ws")
}
