import Foundation
import Synchronization
import Testing
import RVDomain
@testable import RVHooks

private let codec = AntigravityHostCodec()

private func antigravityFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/antigravity/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func antigravityExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try antigravityFixture("\(stem).out")
    let exitText = try antigravityFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

/// Official Antigravity PreToolUse honor path (verified against agy 1.2.11):
/// stdout `{decision:deny,reason}`, exit 0. Codex `decision:block` + exit 2
/// and Claude `permissionDecision` are not this wire.
private func isAntigravityHonorPath(_ wire: HookWire, reason: String) -> Bool {
    let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedReason.isEmpty == false else { return false }
    guard wire.exitCode == 0 else { return false }
    guard let json = try? JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any],
          json["decision"] as? String == "deny",
          json["reason"] as? String == trimmedReason
    else { return false }
    if json["permissionDecision"] != nil { return false }
    if json["hookSpecificOutput"] != nil { return false }
    if json["permission"] != nil { return false }
    if wire.stdout.contains("\"decision\":\"block\"") { return false }
    if wire.stdout.contains("\"decision\":\"ask\"") { return false }
    return true
}

private func assertAntigravityHonorPath(_ wire: HookWire, reason: String) throws {
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == reason)
    #expect(json["permissionDecision"] == nil)
    #expect(json["hookSpecificOutput"] == nil)
    #expect(json["permission"] == nil)
    #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(isAntigravityHonorPath(wire, reason: reason))
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func antigravityDecode_extractsRunCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try antigravityFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .antigravity)
    guard case .shell(_, let command, _, _) = request else {
        Issue.record("expected .shell for \(file)")
        return
    }
    #expect(command.rawValue == expected)
}

@Test(arguments: [
    ("view_file", FileToolKind.read),
    ("write_to_file", FileToolKind.write),
    ("replace_file_content", FileToolKind.edit),
    ("multi_replace_file_content", FileToolKind.edit),
])
func antigravityDecode_fileToolsAreFileDoor(_ tool: String, kind: FileToolKind) {
    let stdin = """
    {"conversationId":"sess_file","toolCall":{"name":"\(tool)","args":{"TargetFile":"/tmp/ws/file.txt"}},"workspacePaths":["/tmp/ws"]}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for \(tool)")
        return
    }
    #expect(request.host == .antigravity)
    guard case .file(_, let file, _, _) = request else {
        Issue.record("expected .file for \(tool)")
        return
    }
    #expect(file.kind == kind)
    #expect(file.path.rawValue == "/tmp/ws/file.txt")
}

@Test func antigravityDecode_absolutePathIsFallbackPathKey() {
    let stdin = """
    {"conversationId":"sess_abs","toolCall":{"name":"view_file","args":{"AbsolutePath":"/tmp/ws/abs.txt"}},"workspacePaths":["/tmp/ws"]}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for AbsolutePath view_file")
        return
    }
    guard case .file(_, let file, _, _) = request else {
        Issue.record("expected .file for AbsolutePath view_file")
        return
    }
    #expect(file.kind == .read)
    #expect(file.path.rawValue == "/tmp/ws/abs.txt")
}

@Test func antigravityDecode_viewFileIsFileTool() throws {
    guard case .request(let request) = codec.decode(try antigravityFixture("allow-non-shell-read.json")) else {
        Issue.record("expected .request for view_file")
        return
    }
    guard case .file(_, let file, _, _) = request else {
        Issue.record("expected .file for view_file")
        return
    }
    #expect(file.kind == .read)
    #expect(file.path.rawValue == "/tmp/ws/README.md")
}

@Test func antigravityDecode_viewFileEnvIsCatalogPath() throws {
    guard case .request(let request) = codec.decode(try antigravityFixture("deny-file-env.json")) else {
        Issue.record("expected .request for deny-file-env")
        return
    }
    guard case .file(_, let file, _, _) = request else {
        Issue.record("expected .file for deny-file-env")
        return
    }
    #expect(file.kind == .read)
    #expect(file.path.rawValue == "/tmp/rv-oracle/.env")
}

@Test func antigravityDecode_viewFileWithoutPathIsFileToolNotForeign() {
    let stdin = #"{"conversationId":"sess","toolCall":{"name":"view_file","args":{}}}"#
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for view_file with empty path")
        return
    }
    guard case .file(_, let file, _, _) = request else {
        Issue.record("expected .file for view_file with empty path")
        return
    }
    #expect(file.kind == .read)
    #expect(file.path.isEmpty == true)
}

@Test func antigravityDecode_otherToolIsForeign() throws {
    #expect(codec.decode(try antigravityFixture("ignore-other-tool.json")) == .foreign)
}

@Test func antigravityDecode_missingToolCallIsForeign() {
    #expect(codec.decode(#"{"conversationId":"sess","workspacePaths":[]}"#) == .foreign)
}

@Test func antigravityDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"toolCall":{"name":"run_command","args":{"CommandLine":""}}}"#)
        == .malformed(.missingCommand))
    #expect(codec.decode(#"{"toolCall":{"name":"run_command","args":{}}}"#)
        == .malformed(.missingCommand))
}

@Test func antigravityDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func antigravityEncodeAllow_isExplicitDecisionAllowNotEmpty() throws {
    let wire = codec.encodeAllow()
    let expected = try antigravityExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "allow")
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.exitCode == 0)
}

@Test func antigravityEncodeDeny_isDecisionDenyExitZero() throws {
    let wire = codec.encodeDeny(reason: resetHardHostDeny)
    let expected = try antigravityExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    try assertAntigravityHonorPath(wire, reason: resetHardHostDeny)
}

@Test func antigravityHonorPath_codexBlockExitTwoIsNotAntigravity() throws {
    let codex = HookWire(
        stdout: hookBlockJSON(reason: resetHardHostDeny),
        exitCode: 2,
        stderr: resetHardHostDeny + "\n"
    )
    #expect(codex.stdout.contains("\"decision\":\"block\""))
    #expect(codex.exitCode == 2)
    #expect(isAntigravityHonorPath(codex, reason: resetHardHostDeny) == false)
    let live = codec.encodeDeny(reason: resetHardHostDeny)
    try assertAntigravityHonorPath(live, reason: resetHardHostDeny)
    #expect(live.exitCode == 0)
    #expect(live.stdout.contains("\"decision\":\"block\"") == false)
}

@Test func antigravityHonorPath_claudePermissionDecisionIsNotAntigravity() throws {
    let claude = HookWire(
        stdout: "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"\(resetHardHostDeny)\"}}\n",
        exitCode: 0
    )
    #expect(isAntigravityHonorPath(claude, reason: resetHardHostDeny) == false)
    let live = codec.encodeDeny(reason: resetHardHostDeny)
    try assertAntigravityHonorPath(live, reason: resetHardHostDeny)
    #expect(live.stdout.contains("\"permissionDecision\"") == false)
}

@Test func antigravityForcedAsk_failClosesToDenyNotAsk() throws {
    let command = ShellCommand(rawValue: "git reset --hard")
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    let result = EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: MatchingView("git reset --hard")
    )
    let wire = hookWire(
        from: result,
        command: command,
        using: AntigravityHostCodec(),
        intent: .firstCall(verdict: .ask(.hostNative), unlockCode: nil)
    )
    try assertAntigravityHonorPath(wire, reason: hostDenyLine(command: command, reason: deny.reason))
    #expect(HostNativeAsk.leftoverAskIsPermit == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
}

@Test func antigravityHookWire_resetHardIsDecisionDeny() throws {
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
        using: AntigravityHostCodec()
    )
    try assertAntigravityHonorPath(wire, reason: resetHardHostDeny)
}

@Test func antigravityHookWire_malformedDenies() async throws {
    let probe = AntigravityEvaluateProbe()
    let wire = await hookWire(host: .antigravity, stdin: "not-json", world: hookWorld { command, _ in
        probe.record(command)
        return EvaluationResult(outcome: .plain)
    })
    #expect(probe.commands.isEmpty)
    try assertAntigravityHonorPath(wire, reason: malformedHookSentence(.unreadable))
}

private final class AntigravityEvaluateProbe: Sendable {
    private let commandsBox = Mutex<[ShellCommand]>([])

    var commands: [ShellCommand] { commandsBox.withLock { $0 } }

    func record(_ command: ShellCommand) {
        commandsBox.withLock { $0.append(command) }
    }
}

@Test func antigravityHookWire_mandatoryHumanIsQuietAllow() throws {
    let deny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )
    let result = EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: "git push origin feature",
        analysis: .unknown,
        boundReview: .mandatoryHuman(deny)
    )
    let wire = hookWire(
        from: result,
        command: ShellCommand(rawValue: "git push origin feature"),
        using: AntigravityHostCodec(),
        cwd: wd("/tmp/ws")
    )
    #expect(
        HostNativeAsk.hostAskVerdict(
            host: .antigravity,
            result: result,
            cwd: wd("/tmp/ws")
        ) == .allow
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "allow")
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
}

@Test func antigravityDecode_readsCwdSessionAndProposedAction() throws {
    guard case .request(let request) = codec.decode(try antigravityFixture("allow-git-status.json")) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/ws")
    #expect(request.session == SessionID(validating: "sess_1"))
    guard case .shell(_, let command, _, _) = request else {
        Issue.record("expected .shell for cwd stdin")
        return
    }
    let action = codec.proposedAction(from: request)
    #expect(
        action.fingerprint
            == ActionFingerprint.make(
                host: .antigravity,
                session: request.session,
                cwd: request.cwd,
                command: command
            )
    )
    guard case .shell(let shell) = action else {
        Issue.record("expected ProposedAction.shell")
        return
    }
    #expect(shell.supportingCommand?.rawValue == "git status")
    #expect(shell.scope.workingDirectory?.rawValue == "/tmp/ws")
    #expect(shell.fingerprint.rawValue == "antigravity:sess_1:/tmp/ws:git status")
}

@Test func antigravityDecode_prefersCwdThenWorkspaceRoot() {
    let stdin = """
    {"conversationId":"sess_ws","toolCall":{"name":"run_command","args":{"CommandLine":"git status"}},"workspacePaths":["/tmp/from-root"]}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for workspace-root cwd")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/from-root")
    #expect(request.session == SessionID(validating: "sess_ws"))
}
