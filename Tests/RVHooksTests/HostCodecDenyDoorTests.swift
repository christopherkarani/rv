import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Test func hookWire_claudeFirstCallDeny_isRichJSONViaHostCodec() throws {
    let command = ShellCommand(rawValue: "git reset --hard")
    let match = RuleMatch(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
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
    let wire = hookWire(
        from: result,
        command: command,
        using: ClaudeHostCodec(),
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"ruleId\":\"core.git:reset-hard\""))
    #expect(wire.stdout.contains("\"packId\":\"core.git\""))
    #expect(wire.stdout.contains("\"severity\":\"critical\""))
    #expect(wire.stdout.contains("\"systemMessage\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(wire.stdout.hasSuffix("\n"))
    assertHookDenyHasNoBypassOrEssay(wire.stdout)
}

@Test func hookWire_museFirstCallDeny_isPermissionDecisionViaHostCodec() throws {
    let command = ShellCommand(rawValue: "git reset --hard")
    let match = RuleMatch(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
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
    let wire = hookWire(
        from: result,
        command: command,
        using: MuseHostCodec(),
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    #expect(wire.exitCode == 0)
    #expect(wire.stderr.isEmpty)
    #expect(wire.stdout.contains("\"hookEventName\":\"PreToolUse\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"permissionDecisionReason\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(wire.stdout.hasSuffix("\n"))
    assertHookDenyHasNoBypassOrEssay(wire.stdout)
}

@Test func hookWire_evaluatedDeny_leftoverCodecIsEncodeDeny() throws {
    let codec = LeftoverVoiceCodec()
    let command = ShellCommand(rawValue: "git reset --hard")
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    )
    let result = EvaluationResult(outcome: .deny(deny, matched: nil))
    let evaluated = hookWire(
        from: result,
        command: command,
        using: codec,
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    let leftover = codec.encodeDeny(
        reason: hostDenyLine(command: command, deny: deny),
        rule: deny.ruleID,
        next: .ttyHint
    )
    #expect(evaluated == leftover)

    let code = try mintedUnlock()
    let mintedEvaluated = hookWire(
        from: result,
        command: command,
        using: codec,
        intent: .firstCall(verdict: .deny, unlockCode: .code(code))
    )
    let mintedLeftover = codec.encodeDeny(
        reason: hostDenyLine(command: command, deny: deny, unlock: .code(code)),
        rule: deny.ruleID,
        next: .minted(code)
    )
    #expect(mintedEvaluated == mintedLeftover)
}

@Test func hookFileWire_deny_leftoverCodecIsEncodeDeny() {
    let codec = LeftoverVoiceCodec()
    let result = secretsEnvFileDeny()
    let file = hookFileWire(from: result, using: codec)
    let ruleID = RuleID(pack: .coreSecrets, pattern: "env")
    let leftover = codec.encodeDeny(
        reason: hostFileDenyLine(deny: Deny(ruleID: ruleID, reason: "Access to a sensitive path is not allowed.")),
        rule: ruleID,
        next: .ttyHint
    )
    #expect(file == leftover)
}

@Test func hookWire_claudeEvaluatedAllowOrIncomplete_isIncompleteDeny() {
    let codec = ClaudeHostCodec()
    let command = ShellCommand(rawValue: "git status")
    let allow = hookWire(
        from: EvaluationResult(outcome: .plain),
        command: command,
        using: codec,
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    let incomplete = codec.encodeDeny(
        reason: indeterminateStopNotice(nil, command: command).text, rule: nil, next: .ttyHint)
    #expect(allow == incomplete)
    #expect(allow != codec.encodeAllow())
    #expect(allow.stdout.contains("rv.indeterminate/incomplete"))

    let oversize = hookWire(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
        command: command,
        using: codec,
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    #expect(
        oversize
            == codec.encodeDeny(
                reason: indeterminateStopNotice(.commandTooLarge, command: command).text, rule: nil, next: .ttyHint))

    let live = hookWire(
        from: EvaluationResult(outcome: .plain),
        command: command,
        using: codec,
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    #expect(live == incomplete)
}

@Test func hookFileWire_claudeMatchedDenyIsRichJSON() {
    let wire = hookFileWire(from: secretsEnvFileDeny(), using: ClaudeHostCodec())
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"ruleId\":\"core.secrets:env\""))
    #expect(wire.stdout.contains("\"packId\":\"core.secrets\""))
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
}

@Test func hookFileWire_claudeUnmatchedAndIncompleteUseEncodeDeny() {
    let codec = ClaudeHostCodec()
    let deny = Deny(
        ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
        reason: "Access to a sensitive path is not allowed."
    )
    let unmatched = EvaluationResult(outcome: .deny(deny, matched: nil))
    #expect(
        hookFileWire(from: unmatched, using: codec)
            == codec.encodeDeny(
                reason: hostFileDenyLine(deny: deny),
                rule: deny.ruleID,
                next: .ttyHint
            )
    )
    #expect(
        hookFileWire(
            from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
            using: codec
        )
            == codec.encodeDeny(
                reason: indeterminateStopNotice(.commandTooLarge, command: nil).text, rule: nil, next: .ttyHint)
    )
    #expect(
        hookFileWire(from: EvaluationResult(outcome: .plain), using: codec)
            == codec.encodeAllow()
    )
}

/// REQ-T4 at the presentation seam: evaluated allow composes the
/// incomplete deny, file allow composes no deny; the matched rule and
/// the ask agent text cross the seam as data.
@Test func presentation_carriesMatchedRuleAndAskAgentText() {
    let command = ShellCommand(rawValue: "git reset --hard")
    let match = RuleMatch(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        severity: .critical,
        reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    )
    let denied = EvaluationResult(
        outcome: .deny(Deny(ruleID: match.ruleID, reason: match.reason), matched: match)
    )

    let deny = denyPresentation(from: denied, command: command, unlockCode: nil)
    #expect(deny.matched == match)
    #expect(deny.rule == match.ruleID)
    #expect(deny.next == .none)
    #expect(deny.agentText == deny.reason)
    #expect(deny.reason == resetHardHostDeny)
    #expect(deny.nextText == ownTerminalLine())

    let ask = askDenyPresentation(
        from: denied,
        command: command,
        unlockCode: nil,
        askRecorded: true
    )
    #expect(ask.matched == match)
    #expect(ask.agentText == ask.reason)
    #if os(macOS)
    #expect(ask.reason == resetHardHostDeny.replacingOccurrences(of: ownTerminalLine(), with: approveInRVLine()))
    #else
    #expect(ask.reason == resetHardHostDeny)
    #endif

    let askUnrecorded = askDenyPresentation(
        from: denied,
        command: command,
        unlockCode: nil,
        askRecorded: false
    )
    #expect(askUnrecorded.agentText == askUnrecorded.reason)
    #expect(askUnrecorded.reason == resetHardHostDeny)

    let evaluatedAllow = denyPresentation(
        from: EvaluationResult(outcome: .plain),
        command: command,
        unlockCode: nil
    )
    #expect(evaluatedAllow.reason == indeterminateStopNotice(nil, command: command).text)
    #expect(evaluatedAllow.matched == nil)
    #expect(fileDenyPresentation(from: EvaluationResult(outcome: .plain)) == nil)
    #expect(fileDenyPresentation(from: denied)?.matched == match)
}

private func secretsEnvFileDeny() -> EvaluationResult {
    let reason = "Access to a sensitive path is not allowed."
    let ruleID = RuleID(pack: .coreSecrets, pattern: "env")
    let matched = RuleMatch(
        ruleID: ruleID,
        severity: .high,
        reason: reason
    )
    return EvaluationResult(
        outcome: .deny(Deny(ruleID: ruleID, reason: reason), matched: matched)
    )
}

private struct LeftoverVoiceCodec: HostCodec {
    var host: HookHost { .pi }

    func decode(_ stdin: String) -> HookDecodeOutcome {
        .malformed(.missingCommand)
    }

    func encodeDeny(_ presentation: HookDenyPresentation) -> HookWire {
        encodeLeftoverDecisionDeny(presentation)
    }
}
