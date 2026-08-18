import Foundation
import Testing
import RVDomain
import RVHooks
import RVPresentation
@testable import RVCLI

private func grokFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVHooksTests/Fixtures/grok/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
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

    func record(_ command: String, result: EvaluationResult) -> EvaluationResult {
        commands.append(command)
        return result
    }
}

@Test func hookAllowGitStatus_emptyStdoutExitZero() async throws {
    let expected = try grokExpected("allow-git-status")
    let wire = await HookRun.run(stdin: try grokFixture("allow-git-status.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookDenyResetHard_reasonEqualsHostDenyText() async throws {
    let expected = try grokExpected("deny-git-reset-hard")
    let command = ShellCommand(rawValue: "git reset --hard")
    let result = CommandRun.evaluateCommand(command.rawValue)
    let text = try #require(hostDenyText(from: result, command: command))
    let wire = await HookRun.run(stdin: try grokFixture("deny-git-reset-hard.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains(text))
    #expect(text.contains("core.git/reset-hard"))
    #expect(text.contains("rv allow-once"))
}

@Test func hookStashDrop_isEmptyAllow() async throws {
    let expected = try grokExpected("allow-medium-stash-drop")
    let wire = await HookRun.run(stdin: try grokFixture("allow-medium-stash-drop.json"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains("deny") == false)
}

@Test func hookOversize_isIndeterminateDenyJSON() async throws {
    let pad = String(repeating: "A", count: 65_537)
    let command = "\(pad) git reset --hard"
    let stdin = """
    {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":\(jsonString(command))}}
    """
    let expected = try grokExpected("deny-indeterminate-oversize")
    let wire = await HookRun.run(stdin: stdin)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains("core.git") == false)
    #expect(wire.stdout.contains("reset-hard") == false)
}

@Test func hookIndeterminate_stillDeniesWhenHostDenyTextNilFallback() async throws {
    let expected = try grokExpected("deny-indeterminate-oversize")
    let wire = await HookRun.run(stdin: try grokFixture("deny-git-reset-hard.json")) { _ in
        EvaluationResult(decision: .indeterminate(.corePacksUnavailable))
    }
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookNonShellRead_doesNotEvaluate() async throws {
    let probe = EvaluateProbe()
    let expected = try grokExpected("allow-non-shell-read")
    let wire = await HookRun.run(stdin: try grokFixture("allow-non-shell-read.json")) { command in
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
    let wire = await HookRun.run(stdin: try grokFixture("malformed.txt"))
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookXPCDown_stillDeniesResetHard() async throws {
    let client = ServiceClient(transport: nil)
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = await HookRun.run(stdin: try grokFixture("deny-git-reset-hard.json")) { command in
        await client.evaluateResult(command: command)
    }
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
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
    let client = ServiceClient(transport: transport)
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = await HookRun.run(stdin: try grokFixture("deny-git-reset-hard.json")) { command in
        await client.evaluateResult(command: command)
    }
    #expect(transport.sendCount == 0)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookBypassPermissionMode_stillEvaluates() async throws {
    let stdin = """
    {"hookEventName":"pre_tool_use","permissionMode":"bypassPermissions","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
    """
    let expected = try grokExpected("deny-git-reset-hard")
    let wire = await HookRun.run(stdin: stdin)
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
}

@Test func hookProcess_deniesResetHardWithTempHomeAndBypassEnv() async throws {
    try await withTempHome { home in
        let binary = try #require(rvBinaryURL())
        let stdin = try grokFixture("deny-git-reset-hard.json")
        let expected = try grokExpected("deny-git-reset-hard")
        let result = try runRV(
            binary: binary,
            arguments: ["hook", "--host", "grok"],
            stdin: stdin,
            home: home,
            extraEnv: ["RV_BYPASS": "1"]
        )
        #expect(result.exit == expected.exit)
        #expect(result.stdout == expected.stdout)
        #expect(result.stderr.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok").path) == false)
    }
}

private func jsonString(_ value: String) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
        let text = String(data: data, encoding: .utf8)
    else {
        return "\"\""
    }
    return text
}

private func rvBinaryURL() -> URL? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        root.appendingPathComponent(".build/debug/rv"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/rv"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func runRV(
    binary: URL,
    arguments: [String],
    stdin: String,
    home: URL,
    extraEnv: [String: String]
) throws -> (stdout: String, stderr: String, exit: Int32) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home.path
    for (key, value) in extraEnv {
        env[key] = value
    }
    process.environment = env
    let inPipe = Pipe()
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
    try inPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (stdout, stderr, process.terminationStatus)
}
