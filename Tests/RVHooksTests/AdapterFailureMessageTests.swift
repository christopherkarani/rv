import Foundation
import RVDomain
import RVHooks
import Testing

/// Python host adapters fail closed with a reason the human can act on:
/// rv's own deny / ask text is carried through, and adapter-level transport
/// failures (missing binary, timeout, unusable output) each say what broke
/// and what to run. Never "rv failed".
struct AdapterFailureMessageTests {
    static let stdinHosts: [HookHost] = [.claude, .codex, .cursor, .antigravity]

    @Test(arguments: stdinHosts)
    func missingBinary_namesPathAndSetup(_ host: HookHost) async throws {
        let run = try await runPythonAdapter(host: host, stub: .missing)
        let reason = try expectFailClosed(host: host, run: run)
        #expect(reason.contains("rv is not installed at \(run.rvPath)"), "\(host): \(reason)")
        #expect(reason.contains("`rv setup`"), "\(host): \(reason)")
    }

    @Test(arguments: stdinHosts)
    func timeout_namesBudgetAndDoctor(_ host: HookHost) async throws {
        let run = try await runPythonAdapter(host: host, stub: .sleep(seconds: 5), timeoutSeconds: "0.3")
        let reason = try expectFailClosed(host: host, run: run)
        #expect(reason.contains("rv did not answer within 0.3s"), "\(host): \(reason)")
        #expect(reason.contains("busy or stopped"), "\(host): \(reason)")
        #expect(reason.contains("`rv doctor`"), "\(host): \(reason)")
    }

    @Test(arguments: stdinHosts)
    func unparseableOutput_namesExitCodeAndDoctor(_ host: HookHost) async throws {
        let run = try await runPythonAdapter(host: host, stub: .stdout("not-json", exit: 3))
        let reason = try expectFailClosed(host: host, run: run)
        #expect(reason.contains("exited with code 3"), "\(host): \(reason)")
        #expect(reason.contains("`rv doctor`"), "\(host): \(reason)")
    }

    @Test(arguments: stdinHosts)
    func emptyOutputNonZeroExit_namesExitCodeAndDoctor(_ host: HookHost) async throws {
        let run = try await runPythonAdapter(host: host, stub: .stdout("", exit: 7))
        let reason = try expectFailClosed(host: host, run: run)
        #expect(reason.contains("exited with code 7"), "\(host): \(reason)")
        #expect(reason.contains("`rv doctor`"), "\(host): \(reason)")
    }

    @Test(arguments: stdinHosts)
    func notExecutable_saysCouldNotStart(_ host: HookHost) async throws {
        let run = try await runPythonAdapter(host: host, stub: .notExecutable)
        let reason = try expectFailClosed(host: host, run: run)
        #expect(reason.contains("rv at \(run.rvPath) could not be started"), "\(host): \(reason)")
        #expect(reason.contains("`rv doctor`"), "\(host): \(reason)")
    }

    @Test(arguments: stdinHosts)
    func unreadableHostRequest_saysSo(_ host: HookHost) async throws {
        let run = try await runPythonAdapter(host: host, stub: .missing, rawEvent: "not json")
        let reason = try expectFailClosed(host: host, run: run)
        #expect(reason.contains("could not read the hook request"), "\(host): \(reason)")
    }

    /// The daemon-down wire `rv hook` really emits for each host (native
    /// ask for Claude / Cursor, deny elsewhere) reaches the human verbatim.
    @Test(arguments: stdinHosts)
    func daemonDownFallback_carriesRvMessage(_ host: HookHost) async throws {
        let run = try await runPythonAdapter(host: host, stub: daemonDownWire(host))
        let reason = try expectFailClosed(host: host, run: run)
        #expect(reason == daemonUnreachableMessage, "\(host): \(reason)")
    }

    @Test func claudeNativeAsk_withoutReasonStillFailsClosedWithGuidance() async throws {
        let wire = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}\n"
        let run = try await runPythonAdapter(host: .claude, stub: .stdout(wire, exit: 0))
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains("`rv doctor`"), "\(reason)")
    }

    @Test func cursorNativeAsk_keepsSplitUserAndAgentMessages() async throws {
        let wire = "{\"permission\":\"ask\",\"user_message\":\"user text\",\"agent_message\":\"agent text\"}\n"
        let run = try await runPythonAdapter(host: .cursor, stub: .stdout(wire, exit: 0))
        let json = try wireObject(run.stdout)
        #expect(json["permission"] as? String == "deny")
        #expect(json["user_message"] as? String == "user text")
        #expect(json["agent_message"] as? String == "agent text")
    }

    // MARK: Hermes (plugin module, not a stdin hook)

    @Test func hermes_missingBinaryNamesPathAndSetup() async throws {
        let run = try await runHermesAdapter(stub: .missing)
        #expect(run.action == "block")
        #expect(run.message?.contains("rv is not installed at \(run.rvPath)") == true, "\(run.message ?? "nil")")
        #expect(run.message?.contains("`rv setup`") == true)
    }

    @Test func hermes_timeoutNamesBudgetAndDoctor() async throws {
        let run = try await runHermesAdapter(stub: .sleep(seconds: 5), timeoutSeconds: "0.3")
        #expect(run.action == "block")
        #expect(run.message?.contains("rv did not answer within 0.3s") == true, "\(run.message ?? "nil")")
        #expect(run.message?.contains("`rv doctor`") == true)
    }

    @Test func hermes_unparseableOutputNamesExitCode() async throws {
        let run = try await runHermesAdapter(stub: .stdout("not-json", exit: 4))
        #expect(run.action == "block")
        #expect(run.message?.contains("exited with code 4") == true, "\(run.message ?? "nil")")
        #expect(run.message?.contains("`rv doctor`") == true)
    }

    @Test func hermes_emptyOutputNonZeroExitNamesExitCode() async throws {
        let run = try await runHermesAdapter(stub: .stdout("", exit: 9))
        #expect(run.action == "block")
        #expect(run.message?.contains("exited with code 9") == true, "\(run.message ?? "nil")")
    }

    @Test func hermes_notExecutableSaysCouldNotStart() async throws {
        let run = try await runHermesAdapter(stub: .notExecutable)
        #expect(run.action == "block")
        #expect(run.message?.contains("could not be started") == true, "\(run.message ?? "nil")")
    }

    @Test func hermes_daemonDownFallbackCarriesRvMessage() async throws {
        let run = try await runHermesAdapter(stub: daemonDownWire(.hermes))
        #expect(run.action == "block")
        #expect(run.message == daemonUnreachableMessage)
    }
}

/// `kUnreachableMessage` in Sources/rv-c/hook_fallback.c.
private let daemonUnreachableMessage =
    "RV daemon is not reachable (dev.rv.evaluate). Run `rv doctor`; `rv setup` repairs the service."

/// Mirrors `rv_hook_fallback_render` for `.unreachable` in the default ask mode.
private func daemonDownWire(_ host: HookHost) -> AdapterStub {
    let msg = daemonUnreachableMessage
    switch host {
    case .claude:
        return .stdout(
            "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(msg)\"},\"systemMessage\":\"\(msg)\"}\n",
            exit: 0
        )
    case .cursor:
        return .stdout("{\"permission\":\"ask\",\"user_message\":\"\(msg)\",\"agent_message\":\"\(msg)\"}\n", exit: 0)
    case .codex:
        return .stdout("{\"decision\":\"block\",\"reason\":\"\(msg)\"}\n", exit: 2)
    case .antigravity:
        return .stdout("{\"decision\":\"deny\",\"reason\":\"\(msg)\"}\n", exit: 0)
    default:
        return .stdout("{\"decision\":\"deny\",\"reason\":\"\(msg)\"}\n", exit: 1)
    }
}

private enum AdapterStub {
    case missing
    case notExecutable
    case stdout(String, exit: Int32)
    case sleep(seconds: Int)
}

private struct PythonAdapterRun {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var rvPath: String
}

private func wireObject(_ stdout: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
}

/// Asserts the host's documented fail-closed wire and returns the text the
/// human sees.
private func expectFailClosed(host: HookHost, run: PythonAdapterRun) throws -> String {
    let json = try wireObject(run.stdout)
    switch host {
    case .claude:
        #expect(run.exitCode == 0)
        let hook = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(hook["permissionDecision"] as? String == "deny")
        let reason = try #require(hook["permissionDecisionReason"] as? String)
        #expect(json["systemMessage"] as? String == reason)
        return reason
    case .codex:
        #expect(run.exitCode == 2)
        #expect(json["decision"] as? String == "block")
        let reason = try #require(json["reason"] as? String)
        #expect(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == reason)
        return reason
    case .cursor:
        #expect(run.exitCode == 0)
        #expect(json["permission"] as? String == "deny")
        return try #require(json["user_message"] as? String)
    case .antigravity:
        #expect(run.exitCode == 0)
        #expect(json["decision"] as? String == "deny")
        return try #require(json["reason"] as? String)
    default:
        Issue.record("not a stdin python adapter: \(host)")
        return ""
    }
}

private func stdinEvent(for host: HookHost) -> [String: Any] {
    switch host {
    case .cursor:
        return ["hook_event_name": "beforeShellExecution", "command": "git status", "cwd": "/tmp/ws"]
    case .antigravity:
        return [
            "conversationId": "sess",
            "toolCall": ["name": "run_command", "args": ["CommandLine": "git status", "Cwd": "/tmp/ws"]],
            "workspacePaths": ["/tmp/ws"],
        ]
    default:
        return [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "cwd": "/tmp/ws",
            "tool_input": ["command": "git status"],
        ]
    }
}

/// Writes the stub rv for `stub` under `root`; returns the baked rv path.
private func writeStub(_ stub: AdapterStub, in root: URL) throws -> String {
    let rvPath = root.appendingPathComponent("rv-stub").path
    switch stub {
    case .missing:
        return root.appendingPathComponent("missing-rv").path
    case .notExecutable:
        try "#!/bin/sh\nexit 0\n".write(toFile: rvPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rvPath)
    case .stdout, .sleep:
        let script = """
        #!/bin/sh
        cat > /dev/null
        if [ -n "$RV_STUB_SLEEP" ]; then
          exec sleep "$RV_STUB_SLEEP"
        fi
        printf '%s' "$RV_STUB_STDOUT"
        exit "${RV_STUB_EXIT:-0}"
        """
        try script.write(toFile: rvPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rvPath)
    }
    return rvPath
}

private func stubEnvironment(_ stub: AdapterStub, root: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = root.path
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    switch stub {
    case .stdout(let stdout, let exitCode):
        environment["RV_STUB_STDOUT"] = stdout
        environment["RV_STUB_EXIT"] = String(exitCode)
    case .sleep(let seconds):
        environment["RV_STUB_SLEEP"] = String(seconds)
    case .missing, .notExecutable:
        break
    }
    return environment
}

private func renderedAdapter(host: HookHost, rvPath: String, timeoutSeconds: String?) throws -> String {
    var source = try HostAdapterResources.load(for: host).rendered(rvPath: rvPath)
    if let timeoutSeconds {
        let original = "RV_HOOK_TIMEOUT_S = 15\n"
        #expect(source.contains(original))
        source = source.replacingOccurrences(of: original, with: "RV_HOOK_TIMEOUT_S = \(timeoutSeconds)\n")
    }
    return source
}

private func runPythonAdapter(
    host: HookHost,
    stub: AdapterStub,
    timeoutSeconds: String? = nil,
    rawEvent: String? = nil
) async throws -> PythonAdapterRun {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-failmsg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let rvPath = try writeStub(stub, in: root)
    let adapter = root.appendingPathComponent("rv-guard.py")
    try renderedAdapter(host: host, rvPath: rvPath, timeoutSeconds: timeoutSeconds)
        .write(to: adapter, atomically: true, encoding: .utf8)

    let eventText: String
    if let rawEvent {
        eventText = rawEvent
    } else {
        let data = try JSONSerialization.data(withJSONObject: stdinEvent(for: host))
        eventText = try #require(String(data: data, encoding: .utf8))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", adapter.path]
    process.environment = stubEnvironment(stub, root: root)
    process.currentDirectoryURL = root
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    stdin.fileHandleForWriting.write(Data(eventText.utf8))
    try stdin.fileHandleForWriting.close()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return PythonAdapterRun(
        stdout: String(decoding: out, as: UTF8.self),
        stderr: String(decoding: err, as: UTF8.self),
        exitCode: process.terminationStatus,
        rvPath: rvPath
    )
}

private struct HermesRun {
    var action: String?
    var message: String?
    var rvPath: String
}

private func runHermesAdapter(stub: AdapterStub, timeoutSeconds: String? = nil) async throws -> HermesRun {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-failmsg-hermes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let rvPath = try writeStub(stub, in: root)
    let adapter = root.appendingPathComponent("rv_guard_hermes.py")
    try renderedAdapter(host: .hermes, rvPath: rvPath, timeoutSeconds: timeoutSeconds)
        .write(to: adapter, atomically: true, encoding: .utf8)
    let harness = root.appendingPathComponent("harness.py")
    try """
    import importlib.util
    import json
    import sys

    spec = importlib.util.spec_from_file_location("rv_guard_hermes", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    result = mod._on_pre_tool_call("terminal", {"command": "git status"}, session_id="s1")
    print(json.dumps({"result": result}))
    """.write(to: harness, atomically: true, encoding: .utf8)

    var environment = stubEnvironment(stub, root: root)
    environment["PYTHONNOUSERSITE"] = "1"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", harness.path, adapter.path]
    process.environment = environment
    process.currentDirectoryURL = root
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: out, as: UTF8.self)
    #expect(process.terminationStatus == 0, "python stderr: \(String(decoding: err, as: UTF8.self))")

    let object = try wireObject(text)
    let mapped = object["result"] as? [String: Any]
    return HermesRun(
        action: mapped?["action"] as? String,
        message: mapped?["message"] as? String,
        rvPath: rvPath
    )
}
