import Foundation
import Testing
import RVDomain
@testable import RVHooks

private let codec = ClaudeHostCodec()
private let resetHard = ShellCommand(rawValue: "git reset --hard")

private func claudeFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func claudeExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try claudeFixture("\(stem).out")
    let exitText = try claudeFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

private let resetHardMatch = RuleMatch(
    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
    packID: .coreGit,
    patternName: "reset-hard",
    severity: .critical,
    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first.",
    explanation: "Discards every uncommitted change."
)

private func resetHardDenyResult() -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: resetHardMatch.ruleID,
                reason: resetHardMatch.reason
            ),
            matched: resetHardMatch
        )
    )
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func claudeDecode_extractsShellCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try claudeFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .claude)
    #expect(request.command.rawValue == expected)
}

@Test(arguments: [
    "allow-non-shell-read.json",
    "allow-non-shell-edit.json",
    "allow-non-shell-write.json",
    "allow-non-shell-mcp.json",
])
func claudeDecode_otherToolOrEventIsForeign(_ file: String) throws {
    #expect(codec.decode(try claudeFixture(file)) == .foreign)
}

@Test func claudeDecode_emptyCommandIsMissingCommand() throws {
    #expect(codec.decode(try claudeFixture("allow-empty-command.json")) == .malformed(.missingCommand))
}

@Test func claudeDecode_malformedIsUnreadable() throws {
    #expect(codec.decode(try claudeFixture("malformed.txt")) == .malformed(.unreadable))
}

@Test func claudeDecode_readsCwdWhenPresent() throws {
    let stdin = """
    {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.command.rawValue == "git status")
    #expect(request.cwd == WorkingDirectory(validating: "/tmp/ws"))
}

@Test func claudeDecode_readsHostAskSpend() {
    let stdin = """
    {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"},"hostAsk":"spend"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for hostAsk spend")
        return
    }
    #expect(request.hostAsk == .spend)
    #expect(request.cwd == WorkingDirectory(validating: "/tmp/ws"))
}

@Test func claudeEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try claudeExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
}

@Test func claudeEncodeRichDeny_matchesResetHardFixture() throws {
    let wire = codec.encodeRichDeny(from: resetHardDenyResult(), command: resetHard)
    let expected = try claudeExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"systemMessage\""))
    #expect(wire.stdout.contains("\"ruleId\":\"core.git:reset-hard\""))
    #expect(wire.stdout.contains("allowOnceCommand") == false)
    #expect(wire.stdout.contains("allowOnceCode") == false)
    #expect(wire.stdout.contains("allowOnceFullHash") == false)
    assertHookDenyHasNoBypassOrEssay(wire.stdout)
}

@Test func claudeEncodeRichDeny_resetHardIsOneShortLine() throws {
    let wire = codec.encodeRichDeny(from: resetHardDenyResult(), command: resetHard)
    let parsed = try claudeDenyObject(wire.stdout)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(parsed.systemMessage == resetHardHostDeny)
    #expect(parsed.permissionDecisionReason == resetHardHostDeny)
    #expect(parsed.systemMessage.contains("\n") == false)
    #expect(parsed.permissionDecisionReason.contains("\n") == false)
    #expect(parsed.systemMessage.hasPrefix("Error:") == false)
    #expect(parsed.systemMessage.components(separatedBy: "RV · Blocked").count == 2)
    #expect(parsed.permissionDecisionReason.components(separatedBy: "RV · Blocked").count == 2)
    assertHookDenyHasNoBypassOrEssay(wire.stdout)
}

@Test func claudeEncodeDeny_indeterminateUsesPlanSentence() throws {
    let wire = codec.encodeDeny(reason: incompleteEvalSentence, rule: nil, next: nil)
    let expected = try claudeExpected("deny-indeterminate-oversize")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains("core.git") == false)
    #expect(wire.stdout.contains("reset-hard") == false)
    #expect(wire.stdout.contains("\"remediation\"") == false)
}

@Test func claudeEncodeDeny_withRuleStillClaudeDenyEnvelope() throws {
    let wire = codec.encodeDeny(
        reason: hostDenyLine(command: resetHard, reason: resetHardMatch.reason),
        rule: displayRuleID(resetHardMatch.ruleID),
        next: hookUnlockNext
    )
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(wire.stdout.contains("allowOnceCode") == false)
    #expect(wire.stdout.contains("\"remediation\"") == false)
}

@Test func claudeEncodeRichDeny_neverEmitsPermissionAsk() throws {
    let leftover = EvaluationResult(
        outcome: .deny(HostNativeAsk.leftoverAskDeny, matched: nil)
    )
    let wire = codec.encodeRichDeny(from: leftover, command: resetHard)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.isEmpty == false)
}

@Test func claudeEncodeRichDeny_unmatchedDenyIsFailClosed() throws {
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: resetHardMatch.ruleID, reason: resetHardMatch.reason),
            matched: nil
        )
    )
    let wire = codec.encodeRichDeny(from: result, command: resetHard)
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("allowOnceCode") == false)
    #expect(wire.stdout.isEmpty == false)
}

private struct ClaudeDenyObject {
    var systemMessage: String
    var permissionDecisionReason: String
}

private func claudeDenyObject(_ stdout: String) throws -> ClaudeDenyObject {
    let data = try #require(stdout.data(using: .utf8))
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let systemMessage = try #require(object["systemMessage"] as? String)
    let hookSpecificOutput = try #require(object["hookSpecificOutput"] as? [String: Any])
    let permissionDecisionReason = try #require(
        hookSpecificOutput["permissionDecisionReason"] as? String
    )
    return ClaudeDenyObject(
        systemMessage: systemMessage,
        permissionDecisionReason: permissionDecisionReason
    )
}
