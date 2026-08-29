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

private func codexExpected(_ stem: String) throws -> (stdout: String, stderr: String, exit: Int32) {
    let stdout = try codexFixture("\(stem).out")
    let exitText = try codexFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    let stderr: String
    if FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex/\(stem).err")
            .path
    ) {
        stderr = try codexFixture("\(stem).err")
    } else {
        stderr = ""
    }
    return (stdout, stderr, code)
}

private func isCodexHonorPath(_ wire: HookWire, reason: String) -> Bool {
    let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStderr = wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedReason.isEmpty == false else { return false }
    guard trimmedStderr.isEmpty == false else { return false }
    guard trimmedStderr == trimmedReason else { return false }
    guard wire.exitCode == 2 else { return false }
    guard let data = wire.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["decision"] as? String == "block",
          json["reason"] as? String == trimmedReason
    else { return false }
    return true
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
    let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStderr = wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmedReason.isEmpty == false)
    #expect(wire.stderr.isEmpty == false)
    #expect(trimmedStderr.isEmpty == false)
    #expect(wire.stderr.contains(reason))
    #expect(trimmedStderr == reason)
    #expect(isCodexHonorPath(wire, reason: reason))
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
    #expect(wire.stderr.isEmpty)
}

@Test func codexHonorPath_stdoutOnlyBlockWithoutStderrReasonIsNotEnough() throws {
    let stdoutOnly = HookWire(
        stdout: hookBlockJSON(reason: resetHardHostDeny),
        exitCode: 2
    )
    #expect(stdoutOnly.stderr.isEmpty)
    #expect(stdoutOnly.stdout.contains("\"decision\":\"block\""))
    #expect(stdoutOnly.exitCode == 2)
    #expect(isCodexHonorPath(stdoutOnly, reason: resetHardHostDeny) == false)
    let live = codec.encodeDeny(reason: resetHardHostDeny)
    #expect(live.stderr.isEmpty == false)
    #expect(live.stderr.contains(resetHardHostDeny))
    #expect(live.stdout == stdoutOnly.stdout)
    #expect(live.exitCode == 2)
    #expect(live != stdoutOnly)
}

@Test(arguments: ["", "\n", " \n", "\n\n", "   ", "\t"])
func codexHonorPath_missingReasonExitTwoWithWhitespaceStderrIsNotEnough(_ missing: String) throws {
    let bad = HookWire(
        stdout: "{\"decision\":\"block\"}\n",
        exitCode: 2,
        stderr: missing
    )
    #expect(bad.exitCode == 2)
    #expect(bad.stdout.contains("\"decision\":\"block\""))
    #expect(bad.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(isCodexHonorPath(bad, reason: resetHardHostDeny) == false)
    #expect(isCodexHonorPath(bad, reason: missing) == false)

    let emitted = hookBlockStderr(reason: missing)
    #expect(emitted != "\n")
    #expect(emitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

    let liveMissing = codec.encodeDeny(reason: missing)
    #expect(liveMissing.exitCode == 2)
    #expect(liveMissing.stdout.contains("\"decision\":\"block\""))
    #expect(liveMissing.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(liveMissing.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    #expect(liveMissing.stderr != "\n")
    #expect(liveMissing != bad)

    let live = codec.encodeDeny(reason: resetHardHostDeny)
    try assertCodexHonorPath(live, reason: resetHardHostDeny)
}

@Test func codexEncodeDeny_isOfficialBlockAndExitTwo() throws {
    let wire = codec.encodeDeny(reason: resetHardHostDeny)
    let expected = try codexExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.stderr == expected.stderr)
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
    #expect(wire.stderr == codec.encodeDeny(reason: resetHardHostDeny).stderr)
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
        bound: .mandatoryHuman(deny),
        cwd: wd("/tmp/ws")
    )
    #expect(HostNativeAsk.capability(for: .codex) == .denyOrTTY)
    #expect(
        HostNativeAsk.verdict(
            host: .codex,
            result: result,
            cwd: wd("/tmp/ws"),
            bound: .mandatoryHuman(deny)
        ) == .deny
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
    #expect(request.session == SessionID(validating: "sess_1"))
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
    #expect(request.session == SessionID(validating: "turn_main"))
}

private final class CodexEvaluateProbe: @unchecked Sendable {
    private(set) var commands: [String] = []

    func record(_ command: ShellCommand) {
        commands.append(command.rawValue)
    }
}
