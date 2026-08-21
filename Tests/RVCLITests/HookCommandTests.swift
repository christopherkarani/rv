import Foundation
import Testing
import RVDomain
import RVHooks
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
            decision: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    ))
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(json["next"] as? String == hookUnlockNext)
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

private final class EvaluateProbe: @unchecked Sendable {
    private(set) var commands: [String] = []

    func record(_ command: ShellCommand, result: EvaluationResult) -> EvaluationResult {
        commands.append(command.rawValue)
        return result
    }
}

private func inProcessEvaluate(_ command: ShellCommand, cwd: String?) async -> EvaluationResult {
    do {
        let client = try isolatedClient(transport: nil)
        return await client.evaluateResult(command: command, cwd: cwd)
    } catch {
        return EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
    }
}

private func runHook<C: HostCodec>(
    stdin: String,
    codec: C = GrokHostCodec(),
    evaluate: (@Sendable (ShellCommand, String?) async -> EvaluationResult)? = nil
) async throws -> HookWire {
    try await withTempHome { _ in
        await HookRun.run(
            stdin: stdin,
            codec: codec,
            evaluate: evaluate ?? inProcessEvaluate
        )
    }
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
    #expect(json["reason"] as? String == text)
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(json["next"] as? String == hookUnlockNext)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains(text))
    #expect(text.contains("core.git/reset-hard"))
    #expect(text.contains("rv allow-once"))
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
        EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
    }
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try grokExpected("allow-non-shell-read")
    let wire = try await runHook(stdin: try grokFixture("allow-non-shell-read.json")) { command, _ in
        probe.record(command, result: EvaluationResult(decision: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run")
        )))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookMalformed_isEmptyAllow() async throws {
    let expected = try grokExpected("malformed")
    let wire = try await runHook(stdin: try grokFixture("malformed.txt"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookXPCDown_stillDeniesResetHard() async throws {
    let client = try isolatedClient(transport: nil)
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = try await runHook(stdin: try grokFixture("deny-git-reset-hard.json")) { command, _ in
        await client.evaluateResult(command: command)
    }
    try expectResetHardMapperDeny(wire, exit: expected.exit)
}

@Test func hookXPCSkew_stillDeniesResetHard() async throws {
    let transport = ScriptedTransport(
        ack: HelloAckView(
            protocolName: "rv.ipc.v0",
            serviceSemver: "1.0.0",
            ok: false,
            skewReason: "protocol"
        )
    )
    let client = try isolatedClient(transport: transport)
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = try await runHook(stdin: try grokFixture("deny-git-reset-hard.json")) { command, _ in
        await client.evaluateResult(command: command)
    }
    #expect(transport.sendCount == 0)
    try expectResetHardMapperDeny(wire, exit: expected.exit)
}

@Test func hookBypassPermissionMode_stillEvaluates() async throws {
    let stdin = """
    {"hookEventName":"pre_tool_use","permissionMode":"bypassPermissions","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
    """
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = try await runHook(stdin: stdin)
    try expectResetHardMapperDeny(wire, exit: expected.exit)
}

@Test func hookAllowEmptyCommand_emptyStdoutExitZero() async throws {
    let expected = try grokExpected("allow-empty-command")
    let wire = try await runHook(stdin: try grokFixture("allow-empty-command.json"))
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
    try expectResetHardMapperDeny(wire, exit: expected.exit)
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
        let outcome = await hook.run(
            stdin: try grokFixture("deny-git-reset-hard.json"),
            evaluate: inProcessEvaluate
        )
        try expectResetHardMapperDeny(
            HookWire(stdout: outcome.stdout, exitCode: outcome.exitCode),
            exit: expected.exit
        )
        #expect(outcome.stderr.isEmpty)
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
}

@Test func hookPiDenyResetHard_reasonEqualsHostDenyText() async throws {
    let expected = try hostExpected("pi", "deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = try await cliEvaluate(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = try await runHook(
        stdin: try hostFixture("pi", "deny-git-reset-hard.json"),
        codec: PiHostCodec()
    )
    let json = try denyJSON(wire.stdout)
    #expect(json["reason"] as? String == text)
    #expect(json["rule"] as? String == "core.git/reset-hard")
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.contains(text))
}

@Test func hookOpenCodeDenyResetHard_reasonEqualsHostDenyText() async throws {
    let expected = try hostExpected("opencode", "deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = try await cliEvaluate(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = try await runHook(
        stdin: try hostFixture("opencode", "deny-git-reset-hard.json"),
        codec: OpenCodeHostCodec()
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
        codec: PiHostCodec()
    ) { command, _ in
        probe.record(command, result: EvaluationResult(decision: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run")
        )))
    }
    #expect(probe.commands.isEmpty)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookOpenCodeNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try hostExpected("opencode", "allow-non-shell-read")
    let wire = try await runHook(
        stdin: try hostFixture("opencode", "allow-non-shell-read.json"),
        codec: OpenCodeHostCodec()
    ) { command, _ in
        probe.record(command, result: EvaluationResult(decision: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "should not run")
        )))
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
        codec: PiHostCodec()
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
        let outcome = await pi.run(
            stdin: try hostFixture("pi", "deny-git-reset-hard.json"),
            evaluate: inProcessEvaluate
        )
        try expectResetHardMapperDeny(
            HookWire(stdout: outcome.stdout, exitCode: outcome.exitCode),
            exit: expected.exit
        )
        #expect(outcome.stderr.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path) == false)

        var openCode = Hook()
        openCode.host = .opencode
        let openExpected = try hostExpected("opencode", "deny-git-reset-hard")
        let openOutcome = await openCode.run(
            stdin: try hostFixture("opencode", "deny-git-reset-hard.json"),
            evaluate: inProcessEvaluate
        )
        try expectResetHardMapperDeny(
            HookWire(stdout: openOutcome.stdout, exitCode: openOutcome.exitCode),
            exit: openExpected.exit
        )
        #expect(openOutcome.stderr.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".config").appendingPathComponent("opencode").path
            ) == false
        )
    }
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
