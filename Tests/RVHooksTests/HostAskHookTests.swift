import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Test func hookWire_piMandatoryHumanEncodesAskNotAllow() throws {
    let deny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )
    let result = EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: "git push origin feature"
    )
    let wire = hookWire(
        from: result,
        command: ShellCommand(rawValue: "git push origin feature"),
        using: PiHostCodec(),
        bound: .mandatoryHuman(deny)
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "ask")
    #expect(json["continuation"] as? String == "hostNative")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.exitCode == 1)
}

@Test func hookWire_openCodeMandatoryHumanEncodesAskNotAllow() throws {
    let deny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )
    let result = EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: "git push origin feature"
    )
    let wire = hookWire(
        from: result,
        command: ShellCommand(rawValue: "git push origin feature"),
        using: OpenCodeHostCodec(),
        bound: .mandatoryHuman(deny)
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "ask")
    #expect(json["continuation"] as? String == "hostNative")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.exitCode == 1)
}

@Test func hookWire_codexMandatoryHumanIsBlockNotAsk() throws {
    let deny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )
    let result = EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: "git push origin feature"
    )
    let wire = hookWire(
        from: result,
        command: ShellCommand(rawValue: "git push origin feature"),
        using: CodexHostCodec(),
        bound: .mandatoryHuman(deny)
    )
    #expect(HostNativeAsk.capability(for: .codex) == .denyOrTTY)
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "block")
    #expect(wire.exitCode == 2)
    #expect(wire.stderr.isEmpty == false)
    #expect(wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    #expect(wire.stderr.contains(deny.reason) || wire.stderr.contains("RV · Blocked"))
}

@Test(arguments: [HookHost.claude, .grok])
func hookWire_firstCallAllowCannotSkipPolicyGate(_ host: HookHost) throws {
    let deny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )
    let result = EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: "git push origin feature"
    )
    let command = ShellCommand(rawValue: "git push origin feature")
    let wire: HookWire
    switch host {
    case .claude:
        wire = hookWire(
            from: result,
            command: command,
            using: ClaudeHostCodec(),
            bound: .mandatoryHuman(deny)
        )
    case .grok:
        wire = hookWire(
            from: result,
            command: command,
            using: GrokHostCodec(),
            bound: .mandatoryHuman(deny)
        )
    default:
        Issue.record("unexpected host \(host)")
        return
    }
    #expect(wire.stdout.isEmpty == false, Comment(rawValue: "\(host) must not encodeAllow"))
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    if host == .claude {
        #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    } else {
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
    }
}

@Test func hookWire_leftoverAskBoundDoesNotPermit() throws {
    let leftover = HostNativeAsk.leftoverAskDeny
    let result = EvaluationResult(
        outcome: .deny(leftover, matched: nil),
        matchingView: "git reset --hard"
    )
    let command = ShellCommand(rawValue: "git reset --hard")
    let pi = hookWire(
        from: result,
        command: command,
        using: PiHostCodec(),
        bound: .deny(leftover)
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(pi.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "deny")
    #expect(HostNativeAsk.leftoverAskIsPermit("ask") == false)
}

@Test func hookWire_afterFailedSpendStaysDeny() throws {
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "x"
    )
    let result = EvaluationResult(outcome: .deny(deny, matched: nil))
    let wire = hookWire(
        from: result,
        command: ShellCommand(rawValue: "git reset --hard"),
        using: PiHostCodec(),
        bound: .mandatoryHuman(deny),
        afterSpend: true
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "deny")
}

@Test func hookWire_spendIntentWithoutCallbackDenies() async throws {
    let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"},"hostAsk":"spend"}
    """
    let wire = await hookWire(host: .pi, stdin: stdin) { _, _ in
        EvaluationResult(outcome: .plain)
    }
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "deny")
    #expect(wire.stdout.isEmpty == false)
}

@Test func hookWire_openCodeSessionShellResetHardIsNotAllow() async throws {
    let stdin = """
    {"tool":"session.shell","args":{"command":"git reset --hard"}}
    """
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "x"
    )
    let leftover = HostNativeAsk.leftoverAskDeny
    let denyWire = await hookWire(host: .opencode, stdin: stdin) { _, _ in
        EvaluationResult(outcome: .deny(deny, matched: nil))
    }
    let leftoverWire = await hookWire(host: .opencode, stdin: stdin) { _, _ in
        EvaluationResult(outcome: .deny(leftover, matched: nil))
    }
    let denyJSON = try #require(
        JSONSerialization.jsonObject(with: Data(denyWire.stdout.utf8)) as? [String: Any]
    )
    let leftoverJSON = try #require(
        JSONSerialization.jsonObject(with: Data(leftoverWire.stdout.utf8)) as? [String: Any]
    )
    #expect(denyWire.stdout.isEmpty == false)
    #expect(denyJSON["decision"] as? String != "allow")
    #expect(leftoverJSON["decision"] as? String == "deny")
    #expect(HostNativeAsk.leftoverAskIsPermit("ask") == false)
}

@Test func hookWire_openCodeSpendIntentWithoutCallbackDenies() async throws {
    let stdin = """
    {"tool":"bash","cwd":"/tmp/ws","args":{"command":"git reset --hard"},"hostAsk":"spend"}
    """
    let wire = await hookWire(host: .opencode, stdin: stdin) { _, _ in
        EvaluationResult(outcome: .plain)
    }
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "deny")
    #expect(wire.stdout.isEmpty == false)
}

@Test func hookWire_claudeSpendIntentWithoutCallbackDenies() async throws {
    let stdin = """
    {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"},"hostAsk":"spend"}
    """
    let wire = await hookWire(host: .claude, stdin: stdin) { _, _ in
        EvaluationResult(outcome: .plain)
    }
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
}

@Test func hookWire_claudeEncodeAskIsNotPermissionAsk() throws {
    let wire = ClaudeHostCodec().encodeAsk(
        reason: "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.",
        rule: "core.git/reset-hard",
        next: hookUnlockNext
    )
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
}
