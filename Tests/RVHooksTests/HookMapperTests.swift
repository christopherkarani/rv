import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Test func hookWire_denyAddsRuleAndNextWithoutBreakingDecisionReason() throws {
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
            matched: nil
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
        from: EvaluationResult(outcome: .plain),
        command: ShellCommand(rawValue: "git status"),
        using: GrokHostCodec()
    )
    #expect(wire.stdout.isEmpty)
    #expect(wire.exitCode == 0)
}

@Test func hookWire_indeterminateOmitsRule() throws {
    let wire = hookWire(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
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

@Test func hookWire_denyAndIndeterminateCallEncodeDeny() {
    let denyCodec = EncodeDenySpy()
    let denyWire = hookWire(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
                matched: nil
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard"),
        using: denyCodec
    )
    #expect(denyWire.stdout == "spy\n")
    #expect(denyWire.exitCode == 9)
    #expect(denyCodec.denyCalls.count == 1)
    #expect(denyCodec.denyCalls[0].rule == "core.git/reset-hard")
    #expect(denyCodec.denyCalls[0].next == hookUnlockNext)

    let incompleteCodec = EncodeDenySpy()
    let incompleteWire = hookWire(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
        command: ShellCommand(rawValue: "x"),
        using: incompleteCodec
    )
    #expect(incompleteWire.stdout == "spy\n")
    #expect(incompleteCodec.denyCalls.count == 1)
    #expect(incompleteCodec.denyCalls[0].reason == incompleteEvalSentence)
    #expect(incompleteCodec.denyCalls[0].rule == nil)
    #expect(incompleteCodec.denyCalls[0].next == nil)
}

private final class EncodeDenySpy: HostCodec, @unchecked Sendable {
    var host: HookHost { .grok }
    private(set) var denyCalls: [(reason: String, rule: String?, next: String?)] = []

    func decode(_ stdin: String) -> HookDecodeOutcome {
        .malformed(.missingCommand)
    }

    func encodeDeny(reason: String, rule: String?, next: String?) -> HookWire {
        denyCalls.append((reason, rule, next))
        return HookWire(stdout: "spy\n", exitCode: 9)
    }
}

@Test func grokDecode_readsCwdWhenPresent() throws {
    let stdin = """
    {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git status"}}
    """
    guard case .request(let request) = GrokHostCodec().decode(stdin) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.command.rawValue == "git status")
    #expect(request.cwd == wd("/tmp/ws"))
}
