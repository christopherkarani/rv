import Foundation
import RVDomain
import RVHooks
import Testing

// Fail-closed cases for the non-Claude host adapters that
// AdapterFailureMessageTests, AdapterHookTests and OpenClawHostAskAdapterTests
// do not reach: rv killed by a signal, a Node adapter that cannot spawn rv, an
// exit-0 reply that is not a usable decision, and Cursor's reasonless native
// ask. Each must block with an actionable reason, never allow or emit ask.

private let failureHosts: [HookHost] = [
    .codex, .cursor, .antigravity, .hermes, .pi, .opencode, .openclaw,
]

private let nodeHosts: [HookHost] = [.pi, .opencode, .openclaw]

private func isNode(_ host: HookHost) -> Bool {
    nodeHosts.contains(host)
}

/// Python sees the negative signal as the return code; Node's `close` gives a null code.
@Test(arguments: failureHosts)
func adapterKilledBySignal_denies(host: HookHost) async throws {
    let outcome = try await runFailingAdapter(host: host, stub: .signal(9))
    let label = Comment(rawValue: "\(host.rawValue): \(outcome.raw)")
    let expected = isNode(host)
        ? "rv was stopped before it returned a decision. Run `rv doctor`."
        : "rv exited with code -9 without a usable decision. Run `rv doctor`."
    #expect(outcome.denied, label)
    #expect(outcome.reason == expected, label)
    #expect(outcome.raw.contains("\"ask\"") == false, label)
}

/// Python hosts are covered by `AdapterFailureMessageTests.notExecutable_saysCouldNotStart`.
@Test(arguments: nodeHosts)
func nodeAdapterSpawnFailure_namesPathAndError(host: HookHost) async throws {
    let outcome = try await runFailingAdapter(host: host, stub: .notExecutable)
    let label = Comment(rawValue: "\(host.rawValue): \(outcome.raw)")
    #expect(outcome.denied, label)
    #expect(
        outcome.reason == "rv at \(outcome.rvPath) could not be started: EACCES. Run `rv doctor`.",
        label
    )
}

@Test(arguments: failureHosts, ["not-json\n", "[1,2]\n", "{\"decision\":\"maybe\"}\n"])
func adapterUnusableReplyWithExitZero_denies(host: HookHost, stdout: String) async throws {
    let outcome = try await runFailingAdapter(host: host, stub: .reply(stdout, exit: 0))
    let label = Comment(rawValue: "\(host.rawValue): \(outcome.raw)")
    #expect(outcome.denied, label)
    #expect(outcome.reason == "rv exited with code 0 without a usable decision. Run `rv doctor`.", label)
}

@Test func cursorDownAskWithoutMessage_deniesWithGuidance() async throws {
    let outcome = try await runFailingAdapter(host: .cursor, stub: .reply("{\"permission\":\"ask\"}\n", exit: 0))
    let label = Comment(rawValue: outcome.raw)
    #expect(outcome.denied, label)
    #expect(outcome.reason == "rv blocked this action without giving a reason. Run `rv doctor`.", label)
    #expect(outcome.raw.contains("\"ask\"") == false, label)
}

// MARK: - Runner

private enum FailureStub: Sendable {
    case reply(String, exit: Int32)
    case signal(Int32)
    case notExecutable
}

private struct FailureOutcome {
    var denied: Bool
    var reason: String?
    var raw: String
    var rvPath: String = ""
}

private func hostEvent(_ host: HookHost) -> [String: Any] {
    switch host {
    case .codex:
        ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "git status"]]
    case .cursor:
        ["hook_event_name": "beforeShellExecution", "command": "git status"]
    case .antigravity:
        ["toolCall": ["name": "run_command", "args": ["CommandLine": "git status", "Cwd": "/tmp"]]]
    case .hermes:
        ["tool_name": "terminal", "args": ["command": "git status"]]
    case .pi:
        ["toolName": "bash", "input": ["command": "git status"]]
    case .opencode:
        ["tool": "bash", "args": ["command": "git status"]]
    default:
        ["toolName": "exec", "params": ["command": "git status"], "toolKind": "exec"]
    }
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/adapters/\(name)")
}

private func writeStubRV(at path: URL, executable: Bool) throws {
    let script = """
    #!/bin/sh
    cat > /dev/null
    if [ -n "$RV_STUB_SIGNAL" ]; then
      kill -"$RV_STUB_SIGNAL" $$
    fi
    printf '%s' "$RV_STUB_STDOUT"
    exit "${RV_STUB_EXIT:-0}"
    """
    try script.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: executable ? 0o755 : 0o644],
        ofItemAtPath: path.path
    )
}

private func runFailingAdapter(
    host: HookHost,
    stub: FailureStub
) async throws -> FailureOutcome {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-fail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let rvPath = root.appendingPathComponent("rv-stub")
    if case .notExecutable = stub {
        try writeStubRV(at: rvPath, executable: false)
    } else {
        try writeStubRV(at: rvPath, executable: true)
    }

    let source = try HostAdapterResources.load(for: host).rendered(rvPath: rvPath.path)

    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = root.path
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    switch stub {
    case .reply(let stdout, let exitCode):
        environment["RV_STUB_STDOUT"] = stdout
        environment["RV_STUB_EXIT"] = String(exitCode)
    case .signal(let signal):
        environment["RV_STUB_SIGNAL"] = String(signal)
    case .notExecutable:
        break
    }

    let eventData = try JSONSerialization.data(withJSONObject: hostEvent(host))
    let eventText = try #require(String(data: eventData, encoding: .utf8))

    let arguments: [String]
    var stdinText: String?
    switch host {
    case .codex, .cursor, .antigravity:
        let adapter = root.appendingPathComponent("rv-guard.py")
        try source.write(to: adapter, atomically: true, encoding: .utf8)
        arguments = ["python3", adapter.path]
        stdinText = eventText
    case .hermes:
        let adapter = root.appendingPathComponent("rv_guard_hermes.py")
        try source.write(to: adapter, atomically: true, encoding: .utf8)
        let harness = root.appendingPathComponent("harness.py")
        try """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("rv_guard_hermes", sys.argv[1])
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        event = json.loads(sys.argv[2])
        print(json.dumps({"result": mod._on_pre_tool_call(event["tool_name"], event["args"])}))
        """.write(to: harness, atomically: true, encoding: .utf8)
        arguments = ["python3", harness.path, adapter.path, eventText]
    case .openclaw:
        try writeOpenClawSDK(in: root)
        let adapter = root.appendingPathComponent("index.js")
        try source.write(to: adapter, atomically: true, encoding: .utf8)
        arguments = ["node", fixtureURL("harness-openclaw.mjs").path, adapter.path, eventText]
    default:
        let adapter = root.appendingPathComponent("adapter.mjs")
        try source.write(to: adapter, atomically: true, encoding: .utf8)
        arguments = ["node", fixtureURL("harness.mjs").path, host.rawValue, adapter.path, eventText]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = root
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    if let stdinText {
        stdin.fileHandleForWriting.write(Data(stdinText.utf8))
    }
    try stdin.fileHandleForWriting.close()
    let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    var outcome = try parseOutcome(host: host, stdout: out, stderr: err, exitCode: process.terminationStatus)
    outcome.rvPath = rvPath.path
    return outcome
}

private func parseOutcome(host: HookHost, stdout: String, stderr: String, exitCode: Int32) throws -> FailureOutcome {
    let raw = "exit=\(exitCode) stdout=\(stdout) stderr=\(stderr)"
    let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] ?? [:]
    let result = object["result"] as? [String: Any]
    switch host {
    case .codex:
        // Codex honors `decision: block` + the same reason on stderr + exit 2.
        let reason = object["reason"] as? String
        let denied = object["decision"] as? String == "block" && exitCode == 2
            && stderr.trimmingCharacters(in: .newlines) == reason
        return FailureOutcome(denied: denied, reason: reason, raw: raw)
    case .cursor:
        let user = object["user_message"] as? String
        let denied = object["permission"] as? String == "deny" && exitCode == 0
            && object["agent_message"] as? String == user
        return FailureOutcome(denied: denied, reason: user, raw: raw)
    case .antigravity:
        let denied = object["decision"] as? String == "deny" && exitCode == 0
        return FailureOutcome(denied: denied, reason: object["reason"] as? String, raw: raw)
    case .hermes:
        let denied = result?["action"] as? String == "block"
        return FailureOutcome(denied: denied, reason: result?["message"] as? String, raw: raw)
    case .pi:
        return FailureOutcome(denied: result?["block"] as? Bool == true, reason: result?["reason"] as? String, raw: raw)
    case .opencode:
        let threw = object["threw"] as? String
        return FailureOutcome(denied: threw != nil, reason: threw, raw: raw)
    default:
        return FailureOutcome(
            denied: result?["block"] as? Bool == true,
            reason: result?["blockReason"] as? String,
            raw: raw
        )
    }
}

private func writeOpenClawSDK(in root: URL) throws {
    let sdk = root.appendingPathComponent("node_modules/openclaw/plugin-sdk", isDirectory: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    try """
    {"name":"openclaw","type":"module","exports":{"./plugin-sdk/plugin-entry":"./plugin-sdk/plugin-entry.js"}}
    """.write(
        to: sdk.deletingLastPathComponent().appendingPathComponent("package.json"),
        atomically: true,
        encoding: .utf8
    )
    try "export function definePluginEntry(definition) {\n  return definition;\n}\n".write(
        to: sdk.appendingPathComponent("plugin-entry.js"),
        atomically: true,
        encoding: .utf8
    )
}
