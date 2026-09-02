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
        bound: .mandatoryHuman(deny),
        cwd: wd("/tmp/ws")
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
        bound: .mandatoryHuman(deny),
        cwd: wd("/tmp/ws")
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

@Test func hookWire_cursorMandatoryHumanIsPermissionDenyNotAsk() throws {
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
        using: CursorHostCodec(),
        bound: .mandatoryHuman(deny)
    )
    #expect(HostNativeAsk.capability(for: .cursor) == .denyOrTTY)
    #expect(HostNativeAsk.capability(for: .pi) == .spendFirst)
    #expect(HostNativeAsk.capability(for: .opencode) == .spendFirst)
    #expect(HostNativeAsk.capability(for: .codex) == .denyOrTTY)
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.stdout.contains("\"permission\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["permission"] as? String == "deny")
    #expect(wire.exitCode == 0)
}

@Test(arguments: [HookHost.grok])
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
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "deny")
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
        bound: .deny(leftover),
        cwd: wd("/tmp/ws")
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
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
    }
    let leftoverWire = await hookWire(host: .opencode, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(leftover, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
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

@Test func hookWire_claudeEncodeAskIsPermissionAskWithoutExtraKeys() throws {
    let wire = ClaudeHostCodec().encodeAsk(
        reason: "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.",
        rule: "core.git/reset-hard",
        next: hookUnlockNext
    )
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"ruleId\"") == false)
    #expect(wire.stdout.contains("\"packId\"") == false)
    #expect(wire.stdout.contains("\"severity\"") == false)
    let parsed = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    let hook = try #require(parsed["hookSpecificOutput"] as? [String: Any])
    #expect(hook.keys.sorted() == ["hookEventName", "permissionDecision", "permissionDecisionReason"])
}

@Test func hookWire_claudeFirstCallPackDenyAsksWhenSpendable() async throws {
    let stdin = """
    {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}
    """
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    let wire = await hookWire(host: .claude, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
    }
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"ruleId\"") == false)
    #expect(wire.exitCode == 0)
}

@Test func hookWire_hermesFirstCallPackDenyAsksWhenSpendable() async throws {
    let stdin = """
    {"toolName":"terminal","cwd":"/tmp/ws","args":{"command":"git reset --hard"}}
    """
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    let wire = await hookWire(host: .hermes, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "ask")
    #expect(json["continuation"] as? String == "hostNative")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.exitCode == 1)
}

@Test func hookWire_claudePermissionRequestSpendsThenAllows() async throws {
    let stdin = """
    {"hook_event_name":"PermissionRequest","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}
    """
    let wire = await hookWire(
        host: .claude,
        stdin: stdin,
        evaluate: { _, _ in
            EvaluationResult(outcome: .plain)
        },
        spendHostAsk: { _, _ in
            EvaluationResult(outcome: .plain)
        }
    )
    #expect(wire.stdout.isEmpty)
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
}

@Test func hookWire_claudePermissionRequestFailedSpendDeniesOnPermissionRequestWire() async throws {
    let stdin = """
    {"hook_event_name":"PermissionRequest","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}
    """
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    let wire = await hookWire(
        host: .claude,
        stdin: stdin,
        evaluate: { _, _ in
            EvaluationResult(outcome: .plain)
        },
        spendHostAsk: { _, _ in
            EvaluationResult(outcome: .deny(deny, matched: nil))
        }
    )
    #expect(wire.stdout.contains("\"hookEventName\":\"PermissionRequest\""))
    #expect(wire.stdout.contains("\"behavior\":\"deny\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.exitCode == 0)
}

@Test func hookWire_piFirstCallPackDenyAsksWhenSpendable() async throws {
    let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"}}
    """
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    let wire = await hookWire(host: .pi, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "ask")
    #expect(json["continuation"] as? String == "hostNative")
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.exitCode == 1)
}

@Test func hookWire_piFirstCallPackDenyWithoutCwdStaysDeny() async throws {
    let stdin = """
    {"toolName":"bash","input":{"command":"git reset --hard"}}
    """
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    let wire = await hookWire(host: .pi, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "deny")
    #expect(json["decision"] as? String != "ask")
    #expect(wire.exitCode == 1)
}

@Test func hookWire_grokFirstCallPackDenyStaysDeny() async throws {
    let stdin = """
    {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
    """
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    let wire = await hookWire(host: .grok, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "deny")
    #expect(json["decision"] as? String != "ask")
}

@Test func hookWire_piFirstCallPackAllowBindsAllow() async throws {
    let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git status"}}
    """
    let wire = await hookWire(host: .pi, stdin: stdin) { _, _ in
        EvaluationResult(outcome: .plain, matchingView: MatchingView("git status"))
    }
    #expect(wire.stdout.isEmpty)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.exitCode == 0)
}

@Test func hookWire_piCarriedMandatoryHumanAsksOnSpendFirstHost() async throws {
    let deny = ActionPolicyEngine.Builtin.remoteBranchAsk
    let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git push --force origin feature"}}
    """
    let wire = await hookWire(host: .pi, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "ask")
    #expect(json["continuation"] as? String == "hostNative")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.exitCode == 1)
}

@Test func hookWire_openCodeCarriedMandatoryHumanAsksOnSpendFirstHost() async throws {
    let deny = ActionPolicyEngine.Builtin.remoteBranchAsk
    let stdin = """
    {"tool":"bash","cwd":"/tmp/ws","args":{"command":"git push --force origin feature"}}
    """
    let wire = await hookWire(host: .opencode, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "ask")
    #expect(json["continuation"] as? String == "hostNative")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.exitCode == 1)
}

@Test func hookWire_piBuiltinDenyWithoutBoundReviewStaysDeny() async throws {
    let deny = ActionPolicyEngine.Builtin.remoteBranchAsk
    let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git push --force origin feature"}}
    """
    let wire = await hookWire(host: .pi, stdin: stdin) { _, _ in
        EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin feature")
        )
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "deny")
    #expect(json["decision"] as? String != "ask")
    #expect(wire.exitCode == 1)
}
