import Foundation
import Synchronization
import Testing
import RVDomain
@testable import RVHooks

private let codec = MuseHostCodec()

private func museFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/muse/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func museExpected(_ stem: String) throws -> (stdout: String, stderr: String, exit: Int32) {
    let stdout = try museFixture("\(stem).out")
    let exitText = try museFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    let stderr: String
    if FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/muse/\(stem).err")
            .path
    ) {
        stderr = try museFixture("\(stem).err")
    } else {
        stderr = ""
    }
    return (stdout, stderr, code)
}

private func isMuseHonorPath(_ wire: HookWire, reason: String) -> Bool {
    let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedReason.isEmpty == false else { return false }
    guard wire.exitCode == 0 else { return false }
    guard wire.stderr.isEmpty else { return false }
    guard let data = wire.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let specific = json["hookSpecificOutput"] as? [String: Any],
          specific["hookEventName"] as? String == "PreToolUse",
          specific["permissionDecision"] as? String == "deny",
          specific["permissionDecisionReason"] as? String == trimmedReason
    else { return false }
    return true
}

private func assertMuseHonorPath(_ wire: HookWire, reason: String) throws {
    let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(specific["hookEventName"] as? String == "PreToolUse")
    #expect(specific["permissionDecision"] as? String == "deny")
    #expect(specific["permissionDecisionReason"] as? String == reason)
    #expect(json["decision"] == nil)
    #expect(json["permission"] == nil)
    #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"allow\"") == false)
    #expect(wire.exitCode == 0)
    #expect(wire.stderr.isEmpty)
    #expect(wire.stdout.hasSuffix("\n"))
    let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmedReason.isEmpty == false)
    #expect(isMuseHonorPath(wire, reason: reason))
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func museDecode_extractsBashCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try museFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .muse)
    guard case .shell(_, let command, _, _) = request else {
        Issue.record("expected .shell for \(file)")
        return
    }
    #expect(command.rawValue == expected)
}

@Test func museDecode_nonBashIsForeign() throws {
    #expect(codec.decode(try museFixture("allow-non-shell-read.json")) == .foreign)
}

@Test func museDecode_capitalBashIsForeign() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}
    """
    #expect(codec.decode(stdin) == .foreign)
}

@Test func museDecode_nonPreToolUseIsForeign() {
    let stdin = """
    {"hook_event_name":"PostToolUse","tool_name":"bash","tool_input":{"command":"git status"}}
    """
    #expect(codec.decode(stdin) == .foreign)
}

@Test func museDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{}}"#)
        == .malformed(.missingCommand))
    #expect(
        codec.decode(#"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":""}}"#)
            == .malformed(.missingCommand)
    )
}

@Test func museDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func museEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try museExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
    #expect(wire.stderr.isEmpty)
}

@Test func museEncodeDeny_isPermissionDecisionAndExitZero() throws {
    let wire = codec.encodeDeny(reason: resetHardHostDeny)
    let expected = try museExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.stderr == expected.stderr)
    #expect(wire.exitCode == expected.exit)
    try assertMuseHonorPath(wire, reason: resetHardHostDeny)
}

@Test(arguments: ["", "\n", " \n", "\n\n", "   ", "\t"])
func museEncodeDeny_blankReasonFallsBackToRvFailed(_ blank: String) throws {
    // The wire requires a non-empty reason; blank input must never emit "".
    let wire = codec.encodeDeny(reason: blank)
    try assertMuseHonorPath(wire, reason: "rv failed")
}

@Test func museHonorPath_codexBlockExitTwoIsNotMuse() throws {
    let codex = HookWire(
        stdout: hookBlockJSON(reason: resetHardHostDeny),
        exitCode: 2,
        stderr: resetHardHostDeny + "\n"
    )
    #expect(codex.stdout.contains("\"decision\":\"block\""))
    #expect(codex.exitCode == 2)
    #expect(isMuseHonorPath(codex, reason: resetHardHostDeny) == false)
    let live = codec.encodeDeny(reason: resetHardHostDeny)
    try assertMuseHonorPath(live, reason: resetHardHostDeny)
    #expect(live.exitCode == 0)
    #expect(live.stdout.contains("\"decision\":\"block\"") == false)
}

@Test func museForcedAsk_failClosesToDenyNotLeftoverAsk() throws {
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
        using: MuseHostCodec(),
        intent: .firstCall(verdict: .ask, unlockCode: nil)
    )
    try assertMuseHonorPath(
        wire,
        reason:
            "\(hostDenyLine(command: command, reason: deny.reason)) \(approvalPendingLine)"
    )
    #expect(HostNativeAsk.leftoverAskIsPermit == false)
    #expect(wire.stdout.contains(approvalPendingLine))
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
}

@Test func museHookWire_resetHardIsPermissionDeny() throws {
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
        using: MuseHostCodec()
    )
    try assertMuseHonorPath(wire, reason: resetHardHostDeny)
}

@Test func museHookWire_malformedDenies() async throws {
    let probe = MuseEvaluateProbe()
    let wire = await hookWire(host: .muse, stdin: "not-json", world: hookWorld { command, _ in
        probe.record(command)
        return EvaluationResult(outcome: .plain)
    })
    #expect(probe.commands.isEmpty)
    try assertMuseHonorPath(wire, reason: malformedHookSentence(.unreadable))
}

@Test func museDecode_readsCwdSessionAndProposedAction() throws {
    guard case .request(let request) = codec.decode(try museFixture("allow-git-status.json")) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/ws")
    #expect(request.session == SessionID(validating: "sess-muse-1"))
    guard case .shell(_, let command, _, _) = request else {
        Issue.record("expected .shell for cwd stdin")
        return
    }
    let action = codec.proposedAction(from: request)
    #expect(
        action.fingerprint
            == ActionFingerprint.make(
                host: .muse,
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
    #expect(shell.fingerprint.rawValue == "muse:sess-muse-1:/tmp/ws:git status")
}

@Test func museDecode_prefersEnvelopeCwdThenWorkdir() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"git status","workdir":"/tmp/from-args"},"cwd":"/tmp/from-envelope"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/from-envelope")
    let fallback = """
    {"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"git status","workdir":"/tmp/from-args"}}
    """
    guard case .request(let fallbackRequest) = codec.decode(fallback) else {
        Issue.record("expected .request for workdir fallback stdin")
        return
    }
    #expect(fallbackRequest.cwd?.rawValue == "/tmp/from-args")
}

@Test func museDecode_emptyCwdIsNil() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"bash","cwd":"","tool_input":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty cwd")
        return
    }
    #expect(request.cwd == nil)
    #expect(request.session == nil)
}

@Test func museDecode_turnIdWhenSessionIdMissing() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"bash","turn_id":"turn_main","tool_input":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for turn_id")
        return
    }
    #expect(request.session == SessionID(validating: "turn_main"))
}

private final class MuseEvaluateProbe: Sendable {
    private let commandsBox = Mutex<[String]>([])

    var commands: [String] { commandsBox.withLock { $0 } }

    func record(_ command: ShellCommand) {
        commandsBox.withLock { $0.append(command.rawValue) }
    }
}
