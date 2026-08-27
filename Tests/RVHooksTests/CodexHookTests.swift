import Foundation
import Testing
import RVDomain
@testable import RVHooks

private let codec = CodexHostCodec()

private func codexFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/codex/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func codexExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try codexFixture("\(stem).out")
    let exitText = try codexFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

private func assertCodexHonorPath(_ wire: HookWire, reason: String) throws {
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "block")
    #expect(json["reason"] as? String == reason)
    #expect(json["permissionDecision"] == nil)
    #expect(json["hookSpecificOutput"] == nil)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(wire.exitCode == 2)
    #expect(wire.stdout.hasSuffix("\n"))
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func codexDecode_extractsBashCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try codexFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .codex)
    #expect(request.command.rawValue == expected)
}

@Test func codexDecode_nonBashIsForeign() throws {
    #expect(codec.decode(try codexFixture("allow-non-shell-read.json")) == .foreign)
}

@Test func codexDecode_nonPreToolUseIsForeign() {
    let stdin = """
    {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}
    """
    #expect(codec.decode(stdin) == .foreign)
}

@Test func codexDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        == .malformed(.missingCommand))
    #expect(
        codec.decode(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":""}}"#)
            == .malformed(.missingCommand)
    )
}

@Test func codexDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func codexEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try codexExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
}

@Test func codexEncodeDeny_isOfficialBlockAndExitTwo() throws {
    let wire = codec.encodeDeny(reason: resetHardHostDeny)
    let expected = try codexExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    try assertCodexHonorPath(wire, reason: resetHardHostDeny)
}

@Test func codexEncodeAsk_isNotAskOrLeftoverAskAsPermit() throws {
    let wire = codec.encodeAsk(
        reason: resetHardHostDeny,
        rule: "core.git/reset-hard",
        next: hookUnlockNext
    )
    try assertCodexHonorPath(wire, reason: resetHardHostDeny)
    #expect(HostNativeAsk.leftoverAskIsPermit("ask") == false)
    #expect(wire.stdout == codec.encodeDeny(reason: resetHardHostDeny).stdout)
    #expect(wire.exitCode == codec.encodeDeny(reason: resetHardHostDeny).exitCode)
}

@Test func codexHookWire_resetHardIsBlockNotClaudeDeny() throws {
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
        using: CodexHostCodec()
    )
    try assertCodexHonorPath(wire, reason: resetHardHostDeny)
}

@Test func codexHookWire_malformedDenies() async throws {
    let probe = CodexEvaluateProbe()
    let wire = await hookWire(host: .codex, stdin: "not-json") { command, _ in
        probe.record(command)
        return EvaluationResult(outcome: .plain)
    }
    #expect(probe.commands.isEmpty)
    try assertCodexHonorPath(wire, reason: malformedHookSentence(.unreadable))
}

@Test func codexHookWire_missingPauseIsDenyOrTTYNeverAllow() throws {
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
    #expect(
        HostNativeAsk.verdict(host: .codex, bound: .mandatoryHuman(deny)) == .deny
    )
    #expect(wire.stdout.isEmpty == false)
    try assertCodexHonorPath(wire, reason: hostDenyLine(command: ShellCommand(rawValue: "git push origin feature"), reason: deny.reason))
}

@Test func codexDecode_readsCwdSessionAndProposedAction() throws {
    guard case .request(let request) = codec.decode(try codexFixture("allow-git-status.json")) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/ws")
    #expect(request.session == "sess_1")
    let action = codec.proposedAction(from: request)
    guard case .shell(let shell) = action else {
        Issue.record("expected ProposedAction.shell")
        return
    }
    #expect(shell.supportingCommand?.rawValue == "git status")
    #expect(shell.scope.workingDirectory?.rawValue == "/tmp/ws")
    #expect(shell.fingerprint.rawValue == "codex:sess_1:/tmp/ws:git status")
}

@Test func codexDecode_prefersWorkdirThenEnvelopeCwd() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status","workdir":"/tmp/from-args"},"cwd":"/tmp/from-envelope"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for workdir stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/from-args")
}

@Test func codexDecode_emptyCwdIsNil() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"","tool_input":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty cwd")
        return
    }
    #expect(request.cwd == nil)
    #expect(request.session == nil)
}

@Test func codexDecode_turnIdWhenSessionIdMissing() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Bash","turn_id":"turn_main","tool_input":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for turn_id")
        return
    }
    #expect(request.session == "turn_main")
}

private final class CodexEvaluateProbe: @unchecked Sendable {
    private(set) var commands: [String] = []

    func record(_ command: ShellCommand) {
        commands.append(command.rawValue)
    }
}
