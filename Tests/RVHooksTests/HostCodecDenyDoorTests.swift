import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Test func hookWire_claudeFirstCallDeny_isRichJSONViaHostCodec() throws {
    let command = ShellCommand(rawValue: "git reset --hard")
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

@Test func encodeEvaluatedDeny_leftoverCodecIsEncodeDeny() throws {
    let codec = LeftoverVoiceCodec()
    let command = ShellCommand(rawValue: "git reset --hard")
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    )
    let result = EvaluationResult(outcome: .deny(deny, matched: nil))
    let evaluated = codec.encodeEvaluatedDeny(
        from: result,
        command: command,
        unlockCode: nil
    )
    let leftover = codec.encodeDeny(
        reason: hostDenyLine(command: command, reason: deny.reason),
        rule: deny.ruleID,
        next: .none
    )
    #expect(evaluated == leftover)

    let code = try mintedUnlock()
    let mintedEvaluated = codec.encodeEvaluatedDeny(
        from: result,
        command: command,
        unlockCode: code
    )
    let mintedLeftover = codec.encodeDeny(
        reason: hostDenyLine(command: command, reason: deny.reason, unlockCode: code),
        rule: deny.ruleID,
        next: .minted(code)
    )
    #expect(mintedEvaluated == mintedLeftover)
}

@Test func hookWire_liveDenyCallsEncodeEvaluatedDeny() {
    let spy = EvaluatedDenyDoorSpy()
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
            matched: nil
        )
    )
    let wire = hookWire(
        from: result,
        command: ShellCommand(rawValue: "git reset --hard"),
        using: spy,
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    #expect(wire.stdout == "evaluated\n")
    #expect(spy.evaluatedCalls == 1)
    #expect(spy.denyCalls == 0)
}

@Test func encodeFileDeny_leftoverCodecIsEncodeDeny() {
    let codec = LeftoverVoiceCodec()
    let result = secretsEnvFileDeny()
    let file = codec.encodeFileDeny(from: result)
    let leftover = codec.encodeDeny(
        reason: hostFileDenyLine(reason: "Access to a sensitive path is not allowed."),
        rule: RuleID(pack: .coreSecrets, pattern: "env"),
        next: .none
    )
    #expect(file == leftover)
}

@Test func encodeEvaluatedDeny_claudeAllowOrIncomplete_isIncompleteDeny() {
    let codec = ClaudeHostCodec()
    let command = ShellCommand(rawValue: "git status")
    let allow = codec.encodeEvaluatedDeny(
        from: EvaluationResult(outcome: .plain),
        command: command,
        unlockCode: nil
    )
    let incomplete = codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    #expect(allow == incomplete)
    #expect(allow != codec.encodeAllow())

    let oversize = codec.encodeEvaluatedDeny(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
        command: command,
        unlockCode: nil
    )
    #expect(oversize == incomplete)

    let live = hookWire(
        from: EvaluationResult(outcome: .plain),
        command: command,
        using: codec,
        intent: .firstCall(verdict: .deny, unlockCode: nil)
    )
    #expect(live == incomplete)
}

@Test func encodeRichDeny_claudeAllowIsIncompleteDeny() {
    let codec = ClaudeHostCodec()
    let allow = codec.encodeRichDeny(
        from: EvaluationResult(outcome: .plain),
        command: ShellCommand(rawValue: "git status"),
        unlockCode: nil
    )
    let incomplete = codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    #expect(allow == incomplete)
    #expect(allow != codec.encodeAllow())
}

@Test func encodeFileDeny_claudeMatchedDenyIsRichJSON() {
    let wire = ClaudeHostCodec().encodeFileDeny(from: secretsEnvFileDeny())
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"ruleId\":\"core.secrets:env\""))
    #expect(wire.stdout.contains("\"packId\":\"core.secrets\""))
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
}

@Test func encodeFileDeny_claudeUnmatchedAndIncompleteUseEncodeDeny() {
    let codec = ClaudeHostCodec()
    let deny = Deny(
        ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
        reason: "Access to a sensitive path is not allowed."
    )
    let unmatched = EvaluationResult(outcome: .deny(deny, matched: nil))
    #expect(
        codec.encodeFileDeny(from: unmatched)
            == codec.encodeDeny(
                reason: hostFileDenyLine(reason: deny.reason),
                rule: deny.ruleID,
                next: .none
            )
    )
    #expect(
        codec.encodeFileDeny(from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)))
            == codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: .none)
    )
    #expect(
        codec.encodeFileDeny(from: EvaluationResult(outcome: .plain))
            == codec.encodeAllow()
    )
}

@Test func hookFileWire_usesEncodeFileDeny() {
    let spy = FileDenyDoorSpy()
    let wire = hookFileWire(from: secretsEnvFileDeny(), using: spy)
    #expect(wire.stdout == "file-deny\n")
    #expect(spy.fileCalls == 1)
    #expect(spy.denyCalls == 0)
}

private func secretsEnvFileDeny() -> EvaluationResult {
    let reason = "Access to a sensitive path is not allowed."
    let ruleID = RuleID(pack: .coreSecrets, pattern: "env")
    let matched = RuleMatch(
        ruleID: ruleID,
        packID: .coreSecrets,
        patternName: "env",
        severity: .high,
        reason: reason
    )
    return EvaluationResult(
        outcome: .deny(Deny(ruleID: ruleID, reason: reason), matched: matched)
    )
}

private struct LeftoverVoiceCodec: HostAskCodec {
    var host: HookHost { .pi }

    func decode(_ stdin: String) -> HookDecodeOutcome {
        .malformed(.missingCommand)
    }

    func encodeDeny(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire {
        encodeLeftoverDecisionDeny(reason: reason, rule: rule, next: next)
    }

    func encodeAsk(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire {
        encodeLeftoverDecisionAsk(reason: reason, rule: rule, next: next)
    }
}

private final class EvaluatedDenyDoorSpy: HostCodec, @unchecked Sendable {
    var host: HookHost { .grok }
    private(set) var evaluatedCalls = 0
    private(set) var denyCalls = 0

    func decode(_ stdin: String) -> HookDecodeOutcome {
        .malformed(.missingCommand)
    }

    func encodeEvaluatedDeny(
        from result: EvaluationResult,
        command: ShellCommand,
        unlockCode: AllowOnceUnlockCode?
    ) -> HookWire {
        evaluatedCalls += 1
        return HookWire(stdout: "evaluated\n", exitCode: 7)
    }

    func encodeDeny(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire {
        denyCalls += 1
        return HookWire(stdout: "deny\n", exitCode: 9)
    }
}

private final class FileDenyDoorSpy: HostCodec, @unchecked Sendable {
    var host: HookHost { .grok }
    private(set) var fileCalls = 0
    private(set) var denyCalls = 0

    func decode(_ stdin: String) -> HookDecodeOutcome {
        .malformed(.missingCommand)
    }

    func encodeFileDeny(from result: EvaluationResult) -> HookWire {
        fileCalls += 1
        return HookWire(stdout: "file-deny\n", exitCode: 7)
    }

    func encodeDeny(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire {
        denyCalls += 1
        return HookWire(stdout: "deny\n", exitCode: 9)
    }
}
