import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Test func hookWire_denyAddsRuleAndNextWithoutBreakingDecisionReason() throws {
    let result = EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
            ),
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
    #expect(json["reason"] as? String == resetHardHostDeny)
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(json["next"] == nil)
    #expect(wire.exitCode == 0)
    assertHookDenyHasNoBypassOrEssay(wire.stdout)
}

@Test(arguments: [HookHost.grok, .pi, .opencode, .openclaw, .hermes, .claude, .codex, .cursor])
func hookWire_samePathHosts_resetHardIsShortDeny(_ host: HookHost) throws {
    let match = RuleMatch(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        packID: .coreGit,
        patternName: "reset-hard",
        severity: .critical,
        reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first.",
        explanation: "Discards every uncommitted change."
    )
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: match.ruleID, reason: match.reason),
            matched: match
        )
    )
    let command = ShellCommand(rawValue: "git reset --hard")
    let wire: HookWire
    switch host {
    case .grok:
        wire = hookWire(from: result, command: command, using: GrokHostCodec())
    case .pi:
        wire = hookWire(from: result, command: command, using: PiHostCodec())
    case .opencode:
        wire = hookWire(from: result, command: command, using: OpenCodeHostCodec())
    case .openclaw:
        wire = hookWire(from: result, command: command, using: OpenClawHostCodec())
    case .hermes:
        wire = hookWire(from: result, command: command, using: HermesHostCodec())
    case .claude:
        wire = hookWire(from: result, command: command, using: ClaudeHostCodec())
    case .codex:
        wire = hookWire(from: result, command: command, using: CodexHostCodec())
    case .cursor:
        wire = hookWire(from: result, command: command, using: CursorHostCodec())
    }
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    if host == .claude {
        #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        let hook = try #require(parsed["hookSpecificOutput"] as? [String: Any])
        #expect(parsed["systemMessage"] as? String == resetHardHostDeny)
        #expect(hook["permissionDecisionReason"] as? String == resetHardHostDeny)
    } else if host == .codex {
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        #expect(json["decision"] as? String == "block")
        #expect(json["reason"] as? String == resetHardHostDeny)
        #expect(json["permissionDecision"] == nil)
        #expect(json["hookSpecificOutput"] == nil)
        #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
        #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
        #expect(wire.exitCode == 2)
        #expect(wire.stderr.isEmpty == false)
        #expect(wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == resetHardHostDeny)
        #expect(wire.stderr.contains(resetHardHostDeny))
    } else if host == .cursor {
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        #expect(json["permission"] as? String == "deny")
        #expect(json["user_message"] as? String == resetHardHostDeny)
        #expect(json["agent_message"] as? String == resetHardHostDeny)
        #expect(json["permissionDecision"] == nil)
        #expect(json["hookSpecificOutput"] == nil)
        #expect(json["decision"] == nil)
        #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
        #expect(wire.stdout.contains("\"permission\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
        #expect(wire.exitCode == 0)
    } else {
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        #expect(json["decision"] as? String == "deny")
        #expect(json["reason"] as? String == resetHardHostDeny)
        #expect(json["next"] == nil)
    }
    assertHookDenyHasNoBypassOrEssay(wire.stdout)
}

@Test func hookWire_piAndOpenCodeStayShortDeny() throws {
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
            matched: nil
        )
    )
    let command = ShellCommand(rawValue: "git reset --hard")
    let pi = hookWire(from: result, command: command, using: PiHostCodec())
    let openCode = hookWire(from: result, command: command, using: OpenCodeHostCodec())
    #expect(pi.stdout.contains("\"permissionDecision\"") == false)
    #expect(pi.stdout.contains("\"decision\":\"deny\""))
    #expect(openCode.stdout.contains("\"permissionDecision\"") == false)
    #expect(openCode.stdout.contains("\"decision\":\"deny\""))
    let openClaw = hookWire(from: result, command: command, using: OpenClawHostCodec())
    #expect(openClaw.stdout.contains("\"permissionDecision\"") == false)
    #expect(openClaw.stdout.contains("\"decision\":\"deny\""))
    #expect(openClaw.exitCode == 1)
    let hermes = hookWire(from: result, command: command, using: HermesHostCodec())
    #expect(hermes.stdout.contains("\"permissionDecision\"") == false)
    #expect(hermes.stdout.contains("\"decision\":\"deny\""))
    #expect(hermes.exitCode == 1)
    let codex = hookWire(from: result, command: command, using: CodexHostCodec())
    #expect(codex.stdout.contains("\"permissionDecision\"") == false)
    #expect(codex.stdout.contains("\"decision\":\"block\""))
    #expect(codex.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(codex.exitCode == 2)
    #expect(codex.stderr.isEmpty == false)
    let cursor = hookWire(from: result, command: command, using: CursorHostCodec())
    #expect(cursor.stdout.contains("\"permissionDecision\"") == false)
    #expect(cursor.stdout.contains("\"permission\":\"deny\""))
    #expect(cursor.stdout.contains("\"decision\":\"block\"") == false)
    #expect(cursor.stdout.contains("\"permission\":\"ask\"") == false)
    #expect(cursor.exitCode == 0)
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

@Test func hookWire_claudeRichDenyUsesEncodeRichDeny() throws {
    let resetHard = ShellCommand(rawValue: "git reset --hard")
    let match = RuleMatch(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        packID: .coreGit,
        patternName: "reset-hard",
        severity: .critical,
        reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first.",
        explanation: "Discards every uncommitted change."
    )
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: match.ruleID, reason: match.reason),
            matched: match
        )
    )
    let wire = hookWire(from: result, command: resetHard, using: ClaudeHostCodec())
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"ruleId\":\"core.git:reset-hard\""))
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
}

@Test func hookWire_claudeAllowIsEmpty() {
    let wire = hookWire(
        from: EvaluationResult(outcome: .plain),
        command: ShellCommand(rawValue: "git status"),
        using: ClaudeHostCodec()
    )
    #expect(wire.stdout.isEmpty)
    #expect(wire.exitCode == 0)
}

@Test func hookWire_claudeIndeterminateOmitsPackFields() throws {
    let wire = hookWire(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
        command: ShellCommand(rawValue: "x"),
        using: ClaudeHostCodec()
    )
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains(incompleteEvalSentence))
    #expect(wire.stdout.contains("core.git") == false)
    #expect(wire.stdout.contains("\"remediation\"") == false)
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
    #expect(denyCodec.denyCalls[0].next == nil)

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

private final class EncodeDoorSpy: HostCodec, @unchecked Sendable {
    let host: HookHost
    private(set) var allowCalls = 0
    private(set) var denyCalls = 0
    private(set) var askCalls = 0

    init(host: HookHost) {
        self.host = host
    }

    func decode(_ stdin: String) -> HookDecodeOutcome {
        .malformed(.missingCommand)
    }

    func encodeAllow() -> HookWire {
        allowCalls += 1
        return HookWire(stdout: "allow\n", exitCode: 0)
    }

    func encodeDeny(reason: String, rule: String?, next: String?) -> HookWire {
        denyCalls += 1
        return HookWire(stdout: "deny\n", exitCode: 9)
    }

    func encodeAsk(reason: String, rule: String?, next: String?) -> HookWire {
        askCalls += 1
        return HookWire(stdout: "ask\n", exitCode: 9)
    }
}

@Test func hookWire_packDoorPiDenyDoesNotEncodeAsk() {
    let deny = Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
    let spy = EncodeDoorSpy(host: .pi)
    _ = hookWire(
        from: EvaluationResult(outcome: .deny(deny, matched: nil)),
        command: ShellCommand(rawValue: "git reset --hard"),
        using: spy
    )
    #expect(spy.allowCalls == 0)
    #expect(spy.denyCalls == 1)
    #expect(spy.askCalls == 0)
}

@Test func hookWire_boundAllowOnDenyResultDoesNotSilentAllow() {
    let deny = Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
    let spy = EncodeDoorSpy(host: .pi)
    _ = hookWire(
        from: EvaluationResult(outcome: .deny(deny, matched: nil)),
        command: ShellCommand(rawValue: "git reset --hard"),
        using: spy,
        bound: .allow
    )
    #expect(spy.allowCalls == 0)
    #expect(spy.denyCalls == 1)
    #expect(spy.askCalls == 0)
}

@Test func hookWire_boundMandatoryHumanPiEncodesAsk() {
    let deny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )
    let spy = EncodeDoorSpy(host: .pi)
    _ = hookWire(
        from: EvaluationResult(outcome: .deny(deny, matched: nil)),
        command: ShellCommand(rawValue: "git push origin feature"),
        using: spy,
        bound: .mandatoryHuman(deny)
    )
    #expect(spy.allowCalls == 0)
    #expect(spy.denyCalls == 0)
    #expect(spy.askCalls == 1)
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
