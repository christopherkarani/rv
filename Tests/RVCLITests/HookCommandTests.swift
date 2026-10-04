import Foundation
import Synchronization
import Testing
import RVDomain
import RVHooks
import RVPolicy
@testable import RVCLI

private func grokFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVHooksTests/Fixtures/grok/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func grokOversizeHookStdin(paddingCount: Int = 65_537) -> String {
    let command = String(repeating: "A", count: paddingCount) + " git reset --hard"
    return """
    {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":\(jsonFragment(command))}}
    """
}

private func jsonFragment(_ value: String) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
        let text = String(data: data, encoding: .utf8)
    else {
        return "\"\""
    }
    return text
}

private func denyJSON(_ stdout: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8))
    return try #require(object as? [String: Any])
}

private func expectResetHardMapperDeny(_ wire: HookWire, exit: Int32) throws {
    let json = try denyJSON(wire.stdout)
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == hostDenyText(
        from: EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                ),
                matched: nil
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    ))
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(json["next"] == nil)
    #expect(wire.exitCode == exit)
}

/// Step 8B ask-denial: a cwd-bound reset-hard is policy ASK, and no host
/// can pause for a human, so the wire renders deny-with-guidance. The
/// verdict stays ASK (pending row + TTY code); only the bytes say deny.
private func expectResetHardAskDeny(_ wire: HookWire, exit: Int32) throws {
    let json = try denyJSON(wire.stdout)
    let line = try #require(hostDenyText(
        from: EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                ),
                matched: nil
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    ))
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == "\(line) \(approvalPendingLine)")
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(json["next"] == nil)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("hostNative") == false)
    #expect(wire.exitCode == exit)
}

private func grokExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try grokFixture("\(stem).out")
    let exitText = try grokFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

private func withTempHome<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-hook-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

private final class EvaluateProbe: Sendable {
    private let box = Mutex<[String]>([])

    var commands: [String] { box.withLock { $0 } }

    func record(_ command: ShellCommand, result: EvaluationResult) -> EvaluationResult {
        box.withLock { $0.append(command.rawValue) }
        return result
    }
}

private func inProcessEvaluate(_ command: ShellCommand, cwd: WorkingDirectory?) async -> EvaluationResult {
    do {
        let client = try isolatedClient(transport: nil)
        return await client.evaluateResult(command: command, cwd: cwd)
    } catch {
        return EvaluationResult(outcome: .indeterminate(.corePacksUnavailable))
    }
}

private func runHook(
    stdin: String,
    host: HookHost = .grok,
    evaluate: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil
) async throws -> HookWire {
    try await withTempHome { _ in
        var hook = Hook()
        hook.host = host
        let wire = await hookWire(
            host: hook.host,
            stdin: stdin,
            world: hookWorld(evaluate: evaluate ?? inProcessEvaluate)
        )
        return wire
    }
}

private func runHonorHook(
    stdin: String,
    host: HookHost = .grok
) async throws -> HookWire {
    let client = try isolatedClient(transport: nil)
    var hook = Hook()
    hook.host = host
    let outcome = await hook.run(stdin: stdin, client: client)
    return HookWire(stdout: outcome.stdout, exitCode: outcome.exitCode, stderr: outcome.stderr)
}

@Test func hookAllowGitStatus_emptyStdoutExitZero() async throws {
    let expected = try grokExpected("allow-git-status")
    let wire = try await runHook(stdin: try grokFixture("allow-git-status.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookDenyResetHard_reasonEqualsHostDenyText() async throws {
    let expected = try grokExpected("deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = try await cliEvaluate(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = try await runHook(stdin: try grokFixture("deny-git-reset-hard.json"))
    let json = try denyJSON(wire.stdout)
    // Step 8B: cwd-bound reset-hard is policy ASK; the wire renders
    // deny-with-guidance (pending row + TTY code carry the ASK).
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == "\(text) \(approvalPendingLine)")
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(json["next"] == nil)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains(text))
    #expect(wire.stdout.contains("git reset --hard") == false)
    #expect(text == "RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.")
    #expect(text.contains("git reset --hard") == false)
    #expect(text.contains("Terminal") == false)
    #expect(text.contains("allow-once") == false)
    #expect(text.components(separatedBy: "RV · Blocked").count == 2)
}

@Test func hookRun_grokDenyThroughClientMintsCode() async throws {
    let directory = try isolatedAllowOnceDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = ServiceClient(
        transport: nil,
        allowOnceDirectory: directory,
        home: try isolatedHome(),
        clock: { now }
    )
    var hook = Hook()
    hook.host = .grok
    let outcome = await hook.run(
        stdin: try grokFixture("deny-git-reset-hard.json"),
        client: client
    )
    let json = try denyJSON(outcome.stdout)
    #expect(json["decision"] as? String == "deny")
    let reason = try #require(json["reason"] as? String)
    let code = try #require(allowOnceUnlockCode(in: reason))
    #expect(json["next"] as? String == unlockLine(for: code))
    #expect(outcome.exitCode == 0)
}

@Test func hookStashDrop_isEmptyAllow() async throws {
    let expected = try grokExpected("allow-medium-stash-drop")
    let wire = try await runHook(stdin: try grokFixture("allow-medium-stash-drop.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains("deny") == false)
}

@Test func hookOversize_isIndeterminateDenyJSON() async throws {
    let expected = try grokExpected("deny-indeterminate-oversize")
    let wire = try await runHook(stdin: grokOversizeHookStdin())
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains("core.git") == false)
    #expect(wire.stdout.contains("reset-hard") == false)
}

@Test func hookIndeterminate_stillDeniesWhenHostDenyTextNilFallback() async throws {
    let expected = try grokExpected("deny-indeterminate-oversize")
    let wire = try await runHook(stdin: try grokFixture("deny-git-reset-hard.json")) { _, _ in
        EvaluationResult(outcome: .indeterminate(.corePacksUnavailable))
    }
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookNonShellRead_allowsOrdinaryFileWithoutPackEvaluate() async throws {
    let expected = try grokExpected("allow-non-shell-read")
    let wire = try await runHonorHook(stdin: try grokFixture("allow-non-shell-read.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookMalformed_failsClosedWithDenyJSONWithoutEvaluating() async throws {
    let probe = EvaluateProbe()
    let expected = try grokExpected("malformed")
    let wire = try await runHook(stdin: try grokFixture("malformed.txt")) { command, _ in
        probe.record(command, result: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run"),
                matched: nil
            )
        ))
    }
    let json = try denyJSON(wire.stdout)
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == malformedHookSentence(.unreadable))
    #expect(json["rule"] == nil)
    #expect(json["next"] == nil)
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookOrdinaryFileStillAllowsAfterFailClosedMalformed() async throws {
    let expected = try grokExpected("allow-non-shell-read")
    let wire = try await runHonorHook(stdin: try grokFixture("allow-non-shell-read.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookFileTool_omittedEvaluateFileFailClosesIncomplete() async throws {
    let probe = EvaluateProbe()
    let wire = try await runHook(stdin: try grokFixture("deny-file-env.json")) { command, _ in
        probe.record(command, result: EvaluationResult(outcome: .plain))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout.contains(incompleteEvalSentence))
    #expect(wire.stdout.contains("core.secrets") == false)
}

@Test func hookGrokFileEnv_deniesCoreSecretsWithoutPackEvaluate() async throws {
    let wire = try await runHonorHook(stdin: try grokFixture("deny-file-env.json"))
    #expect(wire.exitCode == 0)
    let json = try denyJSON(wire.stdout)
    #expect(json["decision"] as? String == "deny")
    #expect(wire.stdout.contains("core.secrets"))
}

@Test func hookClaudeFileEnv_deniesPermissionDecision() async throws {
    let wire = try await runHonorHook(
        stdin: try hostFixture("claude", "deny-file-env.json"),
        host: .claude
    )
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    #expect(wire.stdout.contains("core.secrets"))
}

@Test func hookCursorFileSsh_deniesPermission() async throws {
    let wire = try await runHonorHook(
        stdin: try hostFixture("cursor", "deny-file-ssh.json"),
        host: .cursor
    )
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains("\"permission\":\"deny\""))
    #expect(wire.stdout.contains("\"permissionDecision\"") == false)
}

@Test func hookXPCDown_stillDeniesResetHard() async throws {
    let client = try isolatedClient(transport: nil)
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = try await runHook(stdin: try grokFixture("deny-git-reset-hard.json")) { command, _ in
        await client.evaluateResult(command: command)
    }
    try expectResetHardAskDeny(wire, exit: expected.exit)
}

@Test func hookXPCSkew_stillDeniesResetHard() async throws {
    let transport = ScriptedTransport(
        ack: HelloAckView(
            protocolName: "rv.ipc.v0",
            serviceSemver: "1.0.0",
            status: .skew(.protocolSkew)
        )
    )
    let client = try isolatedClient(transport: transport)
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = try await runHook(stdin: try grokFixture("deny-git-reset-hard.json")) { command, _ in
        await client.evaluateResult(command: command)
    }
    #expect(transport.sendCount == 1)
    #expect(transport.helloCount == 0)
    try expectResetHardAskDeny(wire, exit: expected.exit)
}

@Test func hookBypassPermissionMode_stillEvaluates() async throws {
    let stdin = """
    {"hookEventName":"pre_tool_use","permissionMode":"bypassPermissions","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
    """
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = try await runHook(stdin: stdin)
    try expectResetHardMapperDeny(wire, exit: expected.exit)
}

@Test func hookEmptyCommand_failsClosedWithMissingCommandDenyJSONWithoutEvaluating() async throws {
    let probe = EvaluateProbe()
    let expected = try grokExpected("deny-empty-command")
    let wire = try await runHook(stdin: try grokFixture("deny-empty-command.json")) { command, _ in
        probe.record(command, result: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run"),
                matched: nil
            )
        ))
    }
    let json = try denyJSON(wire.stdout)
    #expect(json["decision"] as? String == "deny")
    #expect(json["reason"] as? String == malformedHookSentence(.missingCommand))
    #expect(json["rule"] == nil)
    #expect(json["next"] == nil)
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookAllowLegacyRunTerminalCmd_emptyStdoutExitZero() async throws {
    let expected = try grokExpected("allow-legacy-run-terminal-cmd")
    let wire = try await runHook(stdin: try grokFixture("allow-legacy-run-terminal-cmd.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookIgnorePassiveSessionStart_emptyStdoutExitZero() async throws {
    let expected = try grokExpected("ignore-passive-session-start")
    let wire = try await runHook(stdin: try grokFixture("ignore-passive-session-start.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookDenyReasonIsOneLine_noBannerOrCSI() async throws {
    let expected = try grokExpected("deny-reason-is-one-line")
    let wire = try await runHook(stdin: try grokFixture("deny-reason-is-one-line.json"))
    try expectResetHardAskDeny(wire, exit: expected.exit)
    let parsed = try grokDenyObject(wire.stdout)
    #expect(parsed.reason.contains("\n") == false)
    #expect(parsed.reason.contains("═") == false)
    #expect(parsed.reason.contains("\u{001B}") == false)
}

@Test func hookRun_deniesResetHardWithoutTouchingTempHome() async throws {
    try await withTempHome { home in
        var hook = Hook()
        hook.host = .grok
        let expected = try grokExpected("deny-git-reset-hard")
        let wire = await hookWire(
            host: hook.host,
            stdin: try grokFixture("deny-git-reset-hard.json"),
            world: hookWorld(evaluate: inProcessEvaluate)
        )
        try expectResetHardAskDeny(wire, exit: expected.exit)
        #expect(wire.stderr.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok").path) == false)
    }
}

@Test func hookUnknownHost_isArgumentParserUsageError() {
    #expect(throws: (any Error).self) {
        try Hook.parse(["--host", "unknown"])
    }
}

@Test func hookHostOption_defaultsToGrok() throws {
    let hook = try Hook.parse([])
    #expect(hook.host == .grok)
}

@Test func hookHostOption_parsesPiAndOpenCode() throws {
    #expect(try Hook.parse(["--host", "pi"]).host == .pi)
    #expect(try Hook.parse(["--host", "opencode"]).host == .opencode)
    #expect(try Hook.parse(["--host", "claude"]).host == .claude)
    #expect(try Hook.parse(["--host", "openclaw"]).host == .openclaw)
    #expect(try Hook.parse(["--host", "hermes"]).host == .hermes)
    #expect(try Hook.parse(["--host", "codex"]).host == .codex)
    #expect(try Hook.parse(["--host", "cursor"]).host == .cursor)
}

@Test func hookClaudeResetHard_encodesAskDeny() async throws {
    let wire = try await runHook(
        stdin: try hostFixture("claude", "deny-git-reset-hard.json"),
        host: .claude
    )
    try assertClaudeAskDenyWire(wire)
}

@Test func hookClaudeAllowGitStatus_emptyStdoutExitZero() async throws {
    let expected = try hostExpected("claude", "allow-git-status")
    let wire = try await runHook(
        stdin: try hostFixture("claude", "allow-git-status.json"),
        host: .claude
    )
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookClaudeOrdinaryFile_allowsWithoutPackEvaluate() async throws {
    let expected = try hostExpected("claude", "allow-non-shell-read")
    let wire = try await runHonorHook(
        stdin: try hostFixture("claude", "allow-non-shell-read.json"),
        host: .claude
    )
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookClaudeXPCDown_stillAskDeniesResetHard() async throws {
    let client = try isolatedClient(transport: nil)
    let wire = try await runHook(
        stdin: try hostFixture("claude", "deny-git-reset-hard.json"),
        host: .claude
    ) { command, _ in
        await client.evaluateResult(command: command)
    }
    try assertClaudeAskDenyWire(wire)
}

@Test func hookRun_claudeAskDenyWithTempHome() async throws {
    try await withTempHome { home in
        var hook = Hook()
        hook.host = .claude
        let wire = await hookWire(
            host: hook.host,
            stdin: try hostFixture("claude", "deny-git-reset-hard.json"),
            world: hookWorld(evaluate: inProcessEvaluate)
        )
        try assertClaudeAskDenyWire(stdout: wire.stdout, exitCode: wire.exitCode)
        #expect(wire.stderr.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) == false)
    }
}

@Test func hookPiDenyResetHard_reasonEqualsHostDenyText() async throws {
    let expected = try hostExpected("pi", "deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = try await cliEvaluate(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = try await runHook(
        stdin: try hostFixture("pi", "deny-git-reset-hard.json"),
        host: .pi
    )
    let json = try denyJSON(wire.stdout)
    #expect(json["reason"] as? String == text)
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.contains(text))
}

@Test func hookPiPresentCwdDeniesWithoutDaemonGrant() async throws {
    // Step 8B.1: no daemon, no memory grant. The hook door denies even
    // with a matching granted projection row on disk.
    let directory = try isolatedAllowOnceDirectory()
    let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
    let store = AllowOnceStore(baseDirectory: directory)
    let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
    let code = try await store.mint(
        matchingView: "git reset --hard",
        cwd: wd("/tmp/ws"),
        ruleID: nil,
        tty: tty,
        now: Date()
    )
    _ = try await store.redeem(code: code.rawValue, tty: tty, now: Date())
    let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"}}
    """
    let wire = try await runHook(stdin: stdin, host: .pi) { command, cwd in
        await client.evaluateResult(command: command, cwd: cwd)
    }
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.contains("\"decision\":\"deny\""))

    let second = await client.evaluateResult(
        command: ShellCommand(rawValue: "git reset --hard"),
        cwd: wd("/tmp/ws")
    )
    guard case .deny(let deny) = second.decision else {
        Issue.record("second evaluate must deny")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:reset-hard")
}

@Test func hookOpenCodeDenyResetHard_reasonEqualsHostDenyText() async throws {
    let expected = try hostExpected("opencode", "deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = try await cliEvaluate(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = try await runHook(
        stdin: try hostFixture("opencode", "deny-git-reset-hard.json"),
        host: .opencode
    )
    let json = try denyJSON(wire.stdout)
    #expect(json["reason"] as? String == text)
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.contains(text))
}

@Test func hookPiNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try hostExpected("pi", "allow-non-shell-read")
    let wire = try await runHook(
        stdin: try hostFixture("pi", "allow-non-shell-read.json"),
        host: .pi
    ) { command, _ in
        probe.record(command, result: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run"),
                matched: nil
            )
        ))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookOpenClawResetHard_encodesAskDeny() async throws {
    let command = ShellCommand(rawValue: "git reset --hard")
    let wire = try await runHook(
        stdin: try hostFixture("openclaw", "deny-git-reset-hard.json"),
        host: .openclaw
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "deny")
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.contains(approvalPendingLine))
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("hostNative") == false)
    #expect(wire.stdout.contains("requireApproval") == false)
}

@Test func hookOpenClawAllowGitStatus_emptyStdoutExitZero() async throws {
    let expected = try hostExpected("openclaw", "allow-git-status")
    let wire = try await runHook(
        stdin: try hostFixture("openclaw", "allow-git-status.json"),
        host: .openclaw
    )
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookOpenClawNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try hostExpected("openclaw", "allow-non-shell-read")
    let wire = try await runHook(
        stdin: try hostFixture("openclaw", "allow-non-shell-read.json"),
        host: .openclaw
    ) { command, _ in
        probe.record(command, result: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run"),
                matched: nil
            )
        ))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookHermesResetHard_encodesAskDeny() async throws {
    let command = ShellCommand(rawValue: "git reset --hard")
    let wire = try await runHook(
        stdin: try hostFixture("hermes", "deny-git-reset-hard.json"),
        host: .hermes
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "deny")
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.contains(approvalPendingLine))
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains("hostNative") == false)
}

@Test func hookHermesAllowGitStatus_emptyStdoutExitZero() async throws {
    let expected = try hostExpected("hermes", "allow-git-status")
    let wire = try await runHook(
        stdin: try hostFixture("hermes", "allow-git-status.json"),
        host: .hermes
    )
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookHermesNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try hostExpected("hermes", "allow-non-shell-read")
    let wire = try await runHook(
        stdin: try hostFixture("hermes", "allow-non-shell-read.json"),
        host: .hermes
    ) { command, _ in
        probe.record(command, result: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run"),
                matched: nil
            )
        ))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookCodexDenyResetHard_isOfficialBlockAndExitTwo() async throws {
    let expected = try hostExpected("codex", "deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = try await cliEvaluate(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = try await runHook(
        stdin: try hostFixture("codex", "deny-git-reset-hard.json"),
        host: .codex
    )
    let json = try denyJSON(wire.stdout)
    // Step 8B: cwd-bound reset-hard is policy ASK; the wire renders
    // block-with-guidance (pending row + TTY code carry the ASK).
    let askLine = "\(text) \(approvalPendingLine)"
    #expect(json["decision"] as? String == "block")
    #expect(json["reason"] as? String == askLine)
    #expect(json["permissionDecision"] == nil)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 2)
    #expect(wire.stdout.contains(text))
    #expect(wire.stderr.isEmpty == false)
    #expect(wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    #expect(wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == askLine)
    #expect(wire.stderr.contains(text))
}

@Test func hookRun_codexDenyWritesStderrReason() async throws {
    try await withTempHome { _ in
        var hook = Hook()
        hook.host = .codex
        let command = ShellCommand(rawValue: "git reset --hard")
        let result = try await cliEvaluate(command.rawValue)
        let text = try #require(hostDenyText(from: result, command: command))
        let wire = await hookWire(
            host: hook.host,
            stdin: try hostFixture("codex", "deny-git-reset-hard.json"),
            world: hookWorld(evaluate: inProcessEvaluate)
        )
        #expect(wire.exitCode == 2)
        #expect(wire.stdout.contains("\"decision\":\"block\""))
        #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
        #expect(wire.stderr.isEmpty == false)
        #expect(wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(wire.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "\(text) \(approvalPendingLine)")
        #expect(wire.stderr.contains(text))
    }
}

@Test func hookCodexAllowGitStatus_emptyStdoutExitZero() async throws {
    let expected = try hostExpected("codex", "allow-git-status")
    let wire = try await runHook(
        stdin: try hostFixture("codex", "allow-git-status.json"),
        host: .codex
    )
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookCodexNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try hostExpected("codex", "allow-non-shell-read")
    let wire = try await runHook(
        stdin: try hostFixture("codex", "allow-non-shell-read.json"),
        host: .codex
    ) { command, _ in
        probe.record(command, result: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run"),
                matched: nil
            )
        ))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookCodexMalformed_deniesWithoutEvaluating() async throws {
    let probe = EvaluateProbe()
    let wire = try await runHook(
        stdin: "not-json",
        host: .codex
    ) { command, _ in
        probe.record(command, result: EvaluationResult(outcome: .plain))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout.contains("\"decision\":\"block\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.exitCode == 2)
    #expect(wire.stderr.isEmpty == false)
}

@Test func hookCursorDenyResetHard_isOfficialPermissionDeny() async throws {
    let expected = try hostExpected("cursor", "deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = try await cliEvaluate(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = try await runHook(
        stdin: try hostFixture("cursor", "deny-git-reset-hard.json"),
        host: .cursor
    )
    let json = try denyJSON(wire.stdout)
    // Step 8B: cwd-bound reset-hard is policy ASK; the user message
    // carries the deny line plus the approval-pending guidance, and the
    // agent message tells the agent to retry after human approval.
    #expect(json["permission"] as? String == "deny")
    #expect(json["user_message"] as? String == "\(text) \(approvalPendingLine)")
    #expect(json["agent_message"] as? String == cursorAgentAskLine)
    #expect(json["permissionDecision"] == nil)
    #expect(json["decision"] == nil)
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
    #expect(wire.stdout.contains("\"permission\":\"ask\"") == false)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 0)
    #expect(wire.stdout.contains(text))
}

@Test func hookCursorAllowGitStatus_isPermissionAllow() async throws {
    let expected = try hostExpected("cursor", "allow-git-status")
    let wire = try await runHook(
        stdin: try hostFixture("cursor", "allow-git-status.json"),
        host: .cursor
    )
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    let json = try denyJSON(wire.stdout)
    #expect(json["permission"] as? String == "allow")
}

@Test func hookCursorOrdinaryFile_allowsWithoutPackEvaluate() async throws {
    let expected = try hostExpected("cursor", "allow-non-shell-read")
    let wire = try await runHonorHook(
        stdin: try hostFixture("cursor", "allow-non-shell-read.json"),
        host: .cursor
    )
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookCursorMalformed_deniesWithoutEvaluating() async throws {
    let probe = EvaluateProbe()
    let wire = try await runHook(
        stdin: "not-json",
        host: .cursor
    ) { command, _ in
        probe.record(command, result: EvaluationResult(outcome: .plain))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout.contains("\"permission\":\"deny\""))
    #expect(wire.stdout.contains("\"permissionDecision\":\"deny\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"block\"") == false)
    #expect(wire.exitCode == 0)
}

@Test func hookHermesMalformed_deniesWithoutEvaluating() async throws {
    let probe = EvaluateProbe()
    let wire = try await runHook(
        stdin: "not-json",
        host: .hermes
    ) { command, _ in
        probe.record(command, result: EvaluationResult(outcome: .plain))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.exitCode == 1)
}

@Test func hookOpenClawMalformed_deniesWithoutEvaluating() async throws {
    let probe = EvaluateProbe()
    let wire = try await runHook(
        stdin: "not-json",
        host: .openclaw
    ) { command, _ in
        probe.record(command, result: EvaluationResult(outcome: .plain))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.exitCode == 1)
}

@Test func hookOpenCodeNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try hostExpected("opencode", "allow-non-shell-read")
    let wire = try await runHook(
        stdin: try hostFixture("opencode", "allow-non-shell-read.json"),
        host: .opencode
    ) { command, _ in
        probe.record(command, result: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run"),
                matched: nil
            )
        ))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookPiXPCDown_stillDeniesResetHard() async throws {
    let client = try isolatedClient(transport: nil)
    let expected = try hostExpected("pi", "deny-git-reset-hard")
    let wire = try await runHook(
        stdin: try hostFixture("pi", "deny-git-reset-hard.json"),
        host: .pi
    ) { command, _ in
        await client.evaluateResult(command: command)
    }
    try expectResetHardMapperDeny(wire, exit: expected.exit)
}

@Test func hookRun_piAndOpenCodeDenyWithTempHome() async throws {
    try await withTempHome { home in
        var pi = Hook()
        pi.host = .pi
        let expected = try hostExpected("pi", "deny-git-reset-hard")
        let wire = await hookWire(
            host: pi.host,
            stdin: try hostFixture("pi", "deny-git-reset-hard.json"),
            world: hookWorld(evaluate: inProcessEvaluate)
        )
        try expectResetHardMapperDeny(wire, exit: expected.exit)
        #expect(wire.stderr.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path) == false)

        var openCode = Hook()
        openCode.host = .opencode
        let openExpected = try hostExpected("opencode", "deny-git-reset-hard")
        let openWire = await hookWire(
            host: openCode.host,
            stdin: try hostFixture("opencode", "deny-git-reset-hard.json"),
            world: hookWorld(evaluate: inProcessEvaluate)
        )
        try expectResetHardMapperDeny(openWire, exit: openExpected.exit)
        #expect(openWire.stderr.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".config").appendingPathComponent("opencode").path
            ) == false
        )
    }
}

/// Step 8B ask-denial: Claude cannot pause for a human and its Ask
/// UI is not authoritative, so a cwd-bound reset-hard renders the rich
/// deny shape with the approval-pending guidance. The verdict stays ASK
/// (pending row + TTY code); the bytes say deny.
private func assertClaudeAskDenyWire(stdout: String, exitCode: Int32) throws {
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
    )
    let output = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(output["permissionDecision"] as? String == "deny")
    #expect((json["systemMessage"] as? String)?.contains(approvalPendingLine) == true)
    #expect((output["permissionDecisionReason"] as? String)?.contains(approvalPendingLine) == true)
    #expect(output["ruleId"] as? String == "core.git:reset-hard")
    #expect(exitCode == 0)
    #expect(stdout.contains("hostNative") == false)
    #expect(stdout.contains("\"decision\":\"allow\"") == false)
    #expect(stdout.contains("\"decision\":\"ask\"") == false)
}

private func assertClaudeAskDenyWire(_ wire: HookWire) throws {
    try assertClaudeAskDenyWire(stdout: wire.stdout, exitCode: wire.exitCode)
}

private func hostFixture(_ host: String, _ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVHooksTests/Fixtures/\(host)/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func hostExpected(_ host: String, _ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try hostFixture(host, "\(stem).out")
    let exitText = try hostFixture(host, "\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

private struct GrokDenyObject {
    var reason: String
}

private func grokDenyObject(_ stdout: String) throws -> GrokDenyObject {
    let data = try #require(stdout.data(using: .utf8))
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let reason = try #require(object["reason"] as? String)
    return GrokDenyObject(reason: reason)
}
