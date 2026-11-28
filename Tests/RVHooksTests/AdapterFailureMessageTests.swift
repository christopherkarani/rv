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

    /// No permission_mode in the request: no proof a human will be asked.
    @Test func claudeNativeAsk_withoutReasonOrModeFailsClosedWithGuidance() async throws {
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

/// The C hook's unreachable stop (`rv_hook_stop_text` in
/// Sources/rv-c/hook_fallback.c) for an account with no usable first name.
let daemonUnreachableMessage = cDownStop("rv.hook/unreachable", why: "rv's daemon is not running", fix: "rv doctor")

/// The C hook's stop for a down class: the B1 shape, no command.
func cDownStop(_ rule: String, why: String, fix: String, owner: String = "your user") -> String {
    "✕ Stopped   (\(rule))\nwhy     \(why)\nwho     ask \(owner) to run  \(fix)"
}

/// `text` as it appears between the quotes of a JSON string.
func jsonStringBody(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

/// Mirrors `rv_hook_fallback_render` for `.unreachable` in the default ask mode.
func daemonDownWire(_ host: HookHost) -> AdapterStub {
    let msg = jsonStringBody(daemonUnreachableMessage)
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

enum AdapterStub {
    case missing
    case notExecutable
    case stdout(String, exit: Int32)
    case sleep(seconds: Int)
}

struct PythonAdapterRun {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var rvPath: String
    /// Every path the adapter opened, recorded only under `.passwdHome`.
    var openedPaths: [String] = []
}

/// Where the Claude adapter looks for the owner config.
enum OwnerConfigLookup {
    /// `_OWNER_CONFIG_PATH` points at the test's file.
    case seam
    /// The adapter's own passwd-home lookup, with the `pw_dir` expression
    /// replaced when `pwDir` is given. The run records every path opened.
    case passwdHome(pwDir: String? = nil)
}

/// Runs the adapter as `__main__` under an audit hook that writes each
/// opened path to stderr, prefixed with `openedPathMarker`.
private let openedPathMarker = "rv-test-opened: "
private let auditedRunner = #"""
import runpy, sys
def _audit(event, args):
    if event == "open" and isinstance(args[0], str):
        sys.stderr.write("rv-test-opened: " + args[0] + "\n")
sys.addaudithook(_audit)
script = sys.argv[1]
sys.argv = sys.argv[1:]
runpy.run_path(script, run_name="__main__")
"""#

func wireObject(_ stdout: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
}

/// Asserts the host's documented fail-closed wire and returns the text the
/// human sees.
func expectFailClosed(host: HookHost, run: PythonAdapterRun) throws -> String {
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
        // The reply goes through a file, not the environment: on macOS
        // Process hands environment values over decomposed (NFD), which
        // would change a non-ASCII owner name the C hook writes as NFC.
        if case .stdout(let stdout, _) = stub {
            try Data(stdout.utf8).write(to: URL(fileURLWithPath: rvPath + ".stdout"))
        }
        let script = """
        #!/bin/sh
        cat > /dev/null
        if [ -n "$RV_STUB_SLEEP" ]; then
          exec sleep "$RV_STUB_SLEEP"
        fi
        cat "$0.stdout"
        exit "${RV_STUB_EXIT:-0}"
        """
        try writeExecutableStub(script, toFile: rvPath)
    }
    return rvPath
}

/// The test process's environment without what the Claude adapter reads
/// to decide whether a person is asked: a test run inside a Claude Code
/// session must not inherit that session's answer.
func adapterTestEnvironment() -> [String: String] {
    ProcessInfo.processInfo.environment.filter { key, _ in
        !key.hasPrefix("CLAUDE_CODE_") && key != "CLAUDECODE" && key != "RV_HOOK_WHEN_DOWN"
    }
}

private func stubEnvironment(_ stub: AdapterStub, root: URL) -> [String: String] {
    var environment = adapterTestEnvironment()
    environment["HOME"] = root.path
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    switch stub {
    case .stdout(_, let exitCode):
        environment["RV_STUB_EXIT"] = String(exitCode)
    case .sleep(let seconds):
        environment["RV_STUB_SLEEP"] = String(seconds)
    case .missing, .notExecutable:
        break
    }
    return environment
}

/// The Claude adapter reads the owner's config from the passwd home. Tests
/// point it at `ownerConfig` instead (never the real home), the way rv.c
/// takes `RV_HOOK_OBSERVE_CONFIG_PATH` at build time.
func pointingOwnerConfig(_ source: String, at ownerConfig: URL) throws -> String {
    let original = "_OWNER_CONFIG_PATH = None\n"
    try #require(source.components(separatedBy: original).count == 2, "owner-config seam missing")
    return source.replacingOccurrences(of: original, with: "_OWNER_CONFIG_PATH = \"\(ownerConfig.path)\"\n")
}

private func renderedAdapter(
    host: HookHost, rvPath: String, timeoutSeconds: String?, ownerConfig: URL, lookup: OwnerConfigLookup
) throws -> String {
    var source = try HostAdapterResources.load(for: host).rendered(rvPath: rvPath)
    switch (host, lookup) {
    case (.claude, .seam):
        source = try pointingOwnerConfig(source, at: ownerConfig)
    case (.claude, .passwdHome(let pwDir?)):
        let original = "pwd.getpwuid(os.getuid()).pw_dir"
        try #require(source.components(separatedBy: original).count == 2, "passwd lookup missing")
        source = source.replacingOccurrences(of: original, with: pwDir)
    default:
        break
    }
    if let timeoutSeconds {
        let original = "RV_HOOK_TIMEOUT_S = 15\n"
        #expect(source.contains(original))
        source = source.replacingOccurrences(of: original, with: "RV_HOOK_TIMEOUT_S = \(timeoutSeconds)\n")
    }
    return source
}

func runPythonAdapter(
    host: HookHost,
    stub: AdapterStub,
    timeoutSeconds: String? = nil,
    rawEvent: String? = nil,
    eventFields: [String: Any] = [:],
    environment extra: [String: String] = [:],
    stdoutUnwritable: Bool = false,
    ownerConfig prepareOwnerConfig: ((URL) throws -> URL)? = nil,
    ownerConfigLookup lookup: OwnerConfigLookup = .seam
) async throws -> PythonAdapterRun {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-failmsg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let rvPath = try writeStub(stub, in: root)
    // The closure prepares the owner config and returns the path the
    // adapter reads (default: a file under `root` that does not exist).
    let defaultOwnerConfig = root.appendingPathComponent("owner-config.json")
    let ownerConfig = try prepareOwnerConfig?(defaultOwnerConfig) ?? defaultOwnerConfig
    // Restore permissions so the cleanup can remove what a test locked.
    defer {
        for locked in [ownerConfig.deletingLastPathComponent(), ownerConfig] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
    }
    let adapter = root.appendingPathComponent("rv-guard.py")
    try renderedAdapter(host: host, rvPath: rvPath, timeoutSeconds: timeoutSeconds, ownerConfig: ownerConfig, lookup: lookup)
        .write(to: adapter, atomically: true, encoding: .utf8)

    let eventText: String
    if let rawEvent {
        eventText = rawEvent
    } else {
        let event = stdinEvent(for: host).merging(eventFields) { _, field in field }
        let data = try JSONSerialization.data(withJSONObject: event)
        eventText = try #require(String(data: data, encoding: .utf8))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    if case .passwdHome = lookup {
        process.arguments = ["python3", "-c", auditedRunner, adapter.path]
    } else {
        process.arguments = ["python3", adapter.path]
    }
    process.environment = stubEnvironment(stub, root: root).merging(extra) { _, value in value }
    process.currentDirectoryURL = root
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    // A read-only descriptor: every write to stdout fails (EBADF).
    let readOnlyStdout = stdoutUnwritable ? FileHandle(forReadingAtPath: "/dev/null") : nil
    if let readOnlyStdout {
        process.standardOutput = readOnlyStdout
    } else {
        process.standardOutput = stdout
    }
    process.standardError = stderr
    try process.run()
    stdin.fileHandleForWriting.write(Data(eventText.utf8))
    try stdin.fileHandleForWriting.close()
    let out = readOnlyStdout == nil ? stdout.fileHandleForReading.readDataToEndOfFile() : Data()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let errLines = String(decoding: err, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
    let opened = errLines.filter { $0.hasPrefix(openedPathMarker) }
    return PythonAdapterRun(
        stdout: String(decoding: out, as: UTF8.self),
        stderr: errLines.filter { !$0.hasPrefix(openedPathMarker) }.joined(separator: "\n"),
        exitCode: process.terminationStatus,
        rvPath: rvPath,
        openedPaths: opened.map { String($0.dropFirst(openedPathMarker.count)) }
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
    try renderedAdapter(
        host: .hermes, rvPath: rvPath, timeoutSeconds: timeoutSeconds,
        ownerConfig: root.appendingPathComponent("owner-config.json"), lookup: .seam)
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
