import Foundation
import Testing
import RVDomain
@testable import RVHooks

private let codec = CursorHostCodec()

private func cursorFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cursor/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func cursorExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try cursorFixture("\(stem).out")
    let exitText = try cursorFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

/// Official Cursor beforeShellExecution honor path
/// (https://cursor.com/docs/hooks.md): stdout `{permission:deny,user_message,agent_message}`.
/// Claude `permissionDecision` and Codex `decision:block` + exit 2 are not Cursor's wire.
private func isCursorHonorPath(_ wire: HookWire, reason: String) -> Bool {
    let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedReason.isEmpty == false else { return false }
    guard wire.exitCode == 0 else { return false }
    guard let json = try? JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any],
          json["permission"] as? String == "deny",
          json["user_message"] as? String == trimmedReason,
          json["agent_message"] as? String == trimmedReason
    else { return false }
    if json["permissionDecision"] != nil { return false }
    if json["hookSpecificOutput"] != nil { return false }
    if json["decision"] != nil { return false }
    if wire.stdout.contains("\"permission\":\"ask\"") { return false }
    if wire.stdout.contains("\"permissionDecision\":\"ask\"") { return false }
    if wire.stdout.contains("\"permissionDecision\":\"deny\"") { return false }
    if wire.stdout.contains("\"decision\":\"block\"") { return false }
    return true
}

private func assertCursorHonorPath(_ wire: HookWire, reason: String) throws {
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["permission"] as? String == "deny")
    #expect(json["user_message"] as? String == reason)
    #expect(json["agent_message"] as? String == reason)
    #expect(json["permissionDecision"] == nil)
    #expect(json["hookSpecificOutput"] == nil)
    #expect(json["decision"] == nil)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permission\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(isCursorHonorPath(wire, reason: reason))
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func cursorDecode_extractsBeforeShellCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try cursorFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .cursor)
    #expect(request.command.rawValue == expected)
}

@Test func cursorDecode_preToolUseShellIsShell() {
    let stdin = """
    {"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"git status","working_directory":"/tmp/from-input"},"cwd":"/tmp/from-envelope","conversation_id":"conv_shell"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for preToolUse Shell")
        return
    }
    #expect(request.host == .cursor)
    #expect(request.command.rawValue == "git status")
    #expect(request.cwd?.rawValue == "/tmp/from-input")
    #expect(request.session == SessionID(validating: "conv_shell"))
}

@Test func cursorDecode_nonShellPreToolUseIsForeign() throws {
    #expect(codec.decode(try cursorFixture("allow-non-shell-read.json")) == .foreign)
}

@Test func cursorDecode_afterShellIsForeign() {
    let stdin = """
    {"hook_event_name":"afterShellExecution","command":"git status","cwd":"/tmp/ws"}
    """
    #expect(codec.decode(stdin) == .foreign)
}

@Test func cursorDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"hook_event_name":"beforeShellExecution","command":""}"#)
        == .malformed(.missingCommand))
    #expect(codec.decode(#"{"hook_event_name":"beforeShellExecution"}"#)
        == .malformed(.missingCommand))
    #expect(
        codec.decode(#"{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{}}"#)
            == .malformed(.missingCommand)
    )
}

@Test func cursorDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func cursorEncodeAllow_isOfficialPermissionAllowNotEmpty() throws {
    let wire = codec.encodeAllow()
    let expected = try cursorExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["permission"] as? String == "allow")
    #expect(json["permission"] as? String != "ask")
    #expect(wire.stdout.contains("\"permission\":\"ask\"") == false)
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.exitCode == 0)
}

@Test func cursorHonorPath_claudePermissionDecisionIsNotCursor() throws {
    let claude = HookWire(
        stdout: "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"\(resetHardHostDeny)\"}}\n",
        exitCode: 0
    )
    #expect(isCursorHonorPath(claude, reason: resetHardHostDeny) == false)
    let live = codec.encodeDeny(reason: resetHardHostDeny)
    try assertCursorHonorPath(live, reason: resetHardHostDeny)
    #expect(live.stdout.contains("\"permissionDecision\"") == false)
}

@Test func cursorHonorPath_codexBlockExitTwoIsNotCursor() throws {
    let codex = HookWire(
        stdout: hookBlockJSON(reason: resetHardHostDeny),
        exitCode: 2,
        stderr: resetHardHostDeny + "\n"
    )
    #expect(codex.stdout.contains("\"decision\":\"block\""))
    #expect(codex.exitCode == 2)
    #expect(isCursorHonorPath(codex, reason: resetHardHostDeny) == false)
    let live = codec.encodeDeny(reason: resetHardHostDeny)
    try assertCursorHonorPath(live, reason: resetHardHostDeny)
    #expect(live.exitCode == 0)
    #expect(live.stdout.contains("\"decision\":\"block\"") == false)
}

@Test func cursorHonorPath_permissionAskIsNotHonorPath() throws {
    let ask = HookWire(
        stdout: "{\"permission\":\"ask\",\"user_message\":\"\(resetHardHostDeny)\"}\n",
        exitCode: 0
    )
    #expect(isCursorHonorPath(ask, reason: resetHardHostDeny) == false)
    let live = codec.encodeAsk(reason: resetHardHostDeny)
    try assertCursorHonorPath(live, reason: resetHardHostDeny)
}

@Test func cursorEncodeDeny_isOfficialPermissionDeny() throws {
    let wire = codec.encodeDeny(reason: resetHardHostDeny)
    let expected = try cursorExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    try assertCursorHonorPath(wire, reason: resetHardHostDeny)
}

@Test func cursorEncodeAsk_isNotAskOrLeftoverAskAsPermit() throws {
    let wire = codec.encodeAsk(
        reason: resetHardHostDeny,
        rule: "core.git/reset-hard",
        next: hookUnlockNext
    )
    try assertCursorHonorPath(wire, reason: resetHardHostDeny)
    #expect(HostNativeAsk.leftoverAskIsPermit("ask") == false)
    #expect(wire.stdout == codec.encodeDeny(reason: resetHardHostDeny).stdout)
    #expect(wire.exitCode == codec.encodeDeny(reason: resetHardHostDeny).exitCode)
    #expect(wire.stdout.contains("\"permission\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
}

@Test func cursorHookWire_resetHardIsPermissionDenyNotClaudeOrCodex() throws {
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
        using: CursorHostCodec()
    )
    try assertCursorHonorPath(wire, reason: resetHardHostDeny)
}

@Test func cursorHookWire_malformedDenies() async throws {
    let probe = CursorEvaluateProbe()
    let wire = await hookWire(host: .cursor, stdin: "not-json") { command, _ in
        probe.record(command)
        return EvaluationResult(outcome: .plain)
    }
    #expect(probe.commands.isEmpty)
    try assertCursorHonorPath(wire, reason: malformedHookSentence(.unreadable))
}

@Test func cursorHookWire_missingPauseIsDenyOrTTYNeverAllow() throws {
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
        bound: .mandatoryHuman(deny),
        cwd: wd("/tmp/ws")
    )
    #expect(HostNativeAsk.capability(for: .cursor) == .denyOrTTY)
    #expect(HostNativeAsk.capability(for: .pi) == .spendFirst)
    #expect(HostNativeAsk.capability(for: .opencode) == .spendFirst)
    #expect(HostNativeAsk.capability(for: .codex) == .denyOrTTY)
    #expect(
        HostNativeAsk.verdict(
            host: .cursor,
            result: result,
            cwd: wd("/tmp/ws"),
            bound: .mandatoryHuman(deny)
        ) == .deny
    )
    #expect(wire.stdout.isEmpty == false)
    try assertCursorHonorPath(
        wire,
        reason: hostDenyLine(
            command: ShellCommand(rawValue: "git push origin feature"),
            reason: deny.reason
        )
    )
}

@Test func cursorDecode_readsCwdSessionAndProposedAction() throws {
    guard case .request(let request) = codec.decode(try cursorFixture("allow-git-status.json")) else {
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
    #expect(shell.fingerprint.rawValue == "cursor:sess_1:/tmp/ws:git status")
}

@Test func cursorDecode_prefersWorkingDirectoryThenCwdThenWorkspaceRoot() {
    let stdin = """
    {"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"git status","working_directory":"/tmp/from-input"},"cwd":"/tmp/from-envelope","workspace_roots":["/tmp/from-root"]}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for working_directory stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/from-input")
}

@Test func cursorDecode_workspaceRootWhenCwdMissing() {
    let stdin = """
    {"hook_event_name":"beforeShellExecution","command":"git status","workspace_roots":["/tmp/from-root"]}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for workspace_roots")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/from-root")
}

@Test func cursorDecode_emptyCwdIsNil() {
    let stdin = """
    {"hook_event_name":"beforeShellExecution","command":"git status","cwd":""}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty cwd")
        return
    }
    #expect(request.cwd == nil)
    #expect(request.session == nil)
}

@Test func cursorDecode_generationIdWhenConversationIdMissing() {
    let stdin = """
    {"hook_event_name":"beforeShellExecution","command":"git status","generation_id":"gen_main"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for generation_id")
        return
    }
    #expect(request.session == SessionID(validating: "gen_main"))
}

@Test func cursorCapability_isDenyOrTTYOnly() {
    #expect(HostNativeAsk.capability(for: .cursor) == .denyOrTTY)
    #expect(HostNativeAsk.capability(for: .pi) == .spendFirst)
    #expect(HostNativeAsk.capability(for: .opencode) == .spendFirst)
    #expect(HostNativeAsk.capability(for: .codex) == .denyOrTTY)
}

private final class CursorEvaluateProbe: @unchecked Sendable {
    private(set) var commands: [String] = []

    func record(_ command: ShellCommand) {
        commands.append(command.rawValue)
    }
}
