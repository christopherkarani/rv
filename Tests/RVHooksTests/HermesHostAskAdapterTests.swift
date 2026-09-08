import Foundation
import RVDomain
import RVHooks
import Testing

private let resetHardReason =
    "RV · Blocked. Destroys uncommitted changes. Use 'git stash' first."
private let resetHardAskReason =
    "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
private let resetHardJSON =
    "{\"decision\":\"deny\",\"reason\":\"RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.\",\"rule\":\"core.git/reset-hard\"}\n"
private let askResetHardJSON =
    "{\"decision\":\"ask\",\"reason\":\"Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.\",\"continuation\":\"hostNative\",\"rule\":\"core.git/reset-hard\",\"next\":\"Run it in Terminal, or rv allow-once.\"}\n"

private func resetHardEvent() -> [String: Any] {
    [
        "tool_name": "terminal",
        "args": [
            "command": "git reset --hard",
            "workdir": "/tmp/ws",
        ],
        "session_id": "sess_1",
    ]
}

@Test func hermesHostAskAdapter_sourceIsConfirmThenSpendNeverApprove() throws {
    let source = try adapterSource(for: .hermes, rvPath: "/opt/rv")
    #expect(source.contains("pre_tool_call"))
    #expect(source.contains("hostAsk"))
    #expect(source.contains("spend"))
    #expect(source.contains("RV_ASK_CONFIRM"))
    #expect(source.contains("request_tool_approval"))
    #expect(source.contains("rv-ask:"))
    #expect(source.contains("uuid.uuid4"))
    #expect(source.contains("rule_key"))
    #expect(source.contains("\"action\": \"approve\"") == false)
    #expect(source.contains("RV_BYPASS") == false)
}

@Test func hermesHostAskAdapter_confirmYesSpendsThenAllows() async throws {
    let result = try await runHermesAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "yes",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.action == nil)
    #expect(result.message == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.lastStdin?.contains("git reset --hard") == true)
}

@Test func hermesHostAskAdapter_confirmYesFailedSpendDoesNotRunTool() async throws {
    let result = try await runHermesAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "yes",
        secondStub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.action == "block")
    #expect(result.message == resetHardReason)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func hermesHostAskAdapter_confirmYesMissingSpendDoesNotRunTool() async throws {
    let result = try await runHermesAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "yes"
    )
    #expect(result.action == "block")
    #expect(result.spawnCount == 2)
}

@Test func hermesHostAskAdapter_confirmNoDoesNotSpend() async throws {
    let result = try await runHermesAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "no",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.action == "block")
    #expect(result.message == resetHardAskReason)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func hermesHostAskAdapter_missingConfirmDoesNotSpend() async throws {
    let result = try await runHermesAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.action == "block")
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func hermesHostAskAdapter_confirmTimeoutDoesNotSpend() async throws {
    let result = try await runHermesAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        approvalProbe: .timeout,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.action == "block")
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func hermesHostAskAdapter_denyJSONDoesNotPause() async throws {
    let result = try await runHermesAdapter(
        event: resetHardEvent(),
        stub: .stdout(resetHardJSON, exit: 1),
        confirm: "yes",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.action == "block")
    #expect(result.message == resetHardReason)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

private func adapterSource(for host: HookHost, rvPath: String) throws -> String {
    try HostAdapterResources.load(for: host).rendered(rvPath: rvPath)
}

private enum StubRV {
    case missing
    case stdout(String, exit: Int32)
    case sleep(seconds: Int)
}

private enum ApprovalProbe {
    case timeout
}

private struct HermesAdapterRun {
    var action: String?
    var message: String?
    var spawned: Bool
    var spawnCount: Int
    var lastStdin: String?
}

private func runHermesAdapter(
    event: [String: Any],
    stub: StubRV,
    confirm: String? = nil,
    approvalProbe: ApprovalProbe? = nil,
    secondStub: StubRV? = nil
) async throws -> HermesAdapterRun {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-hermes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stubDir = root.appendingPathComponent("stub", isDirectory: true)
    try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)

    let rvPath: String
    switch stub {
    case .missing:
        rvPath = root.appendingPathComponent("missing-rv").path
    case .stdout, .sleep:
        rvPath = root.appendingPathComponent("rv-stub").path
        let script = """
        #!/bin/sh
        n=0
        if [ -n "$RV_STUB_DIR" ]; then
          mkdir -p "$RV_STUB_DIR"
          if [ -f "$RV_STUB_DIR/n" ]; then
            n=$(cat "$RV_STUB_DIR/n")
          fi
          n=$((n+1))
          echo "$n" > "$RV_STUB_DIR/n"
          echo spawned > "$RV_STUB_DIR/spawned"
          cat > "$RV_STUB_DIR/stdin.$n"
          cp "$RV_STUB_DIR/stdin.$n" "$RV_STUB_DIR/stdin"
        fi
        if [ -n "$RV_STUB_SLEEP" ]; then
          sleep "$RV_STUB_SLEEP"
        fi
        if [ "$n" -ge 2 ] && [ -n "${RV_STUB_STDOUT_2+x}" ]; then
          printf '%s' "$RV_STUB_STDOUT_2"
          exit "${RV_STUB_EXIT_2:-0}"
        fi
        if [ -n "$RV_STUB_STDOUT" ]; then
          printf '%s' "$RV_STUB_STDOUT"
        fi
        exit "${RV_STUB_EXIT:-0}"
        """
        try script.write(toFile: rvPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rvPath
        )
    }

    let source = try adapterSource(for: .hermes, rvPath: rvPath)
    let adapter = root.appendingPathComponent("rv-guard-hermes.py")
    try source.write(to: adapter, atomically: true, encoding: .utf8)

    let harness = root.appendingPathComponent("harness.py")
    let harnessSource = """
    import importlib.util
    import json
    import sys

    path = sys.argv[1]
    event = json.loads(sys.argv[2])
    spec = importlib.util.spec_from_file_location("rv_guard_hermes", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    kwargs = {k: v for k, v in event.items() if k not in ("tool_name", "args")}
    result = mod._on_pre_tool_call(
        event.get("tool_name", "terminal"),
        event.get("args"),
        **kwargs,
    )
    print(json.dumps({"result": result}))
    """
    try harnessSource.write(to: harness, atomically: true, encoding: .utf8)

    let pythonPath: String
    if case .timeout = approvalProbe {
        let site = root.appendingPathComponent("pysite", isDirectory: true)
        let tools = site.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try "".write(
            to: tools.appendingPathComponent("__init__.py"),
            atomically: true,
            encoding: .utf8
        )
        try """
        def request_tool_approval(*args, **kwargs):
            raise TimeoutError("approval timed out")
        """.write(
            to: tools.appendingPathComponent("approval.py"),
            atomically: true,
            encoding: .utf8
        )
        pythonPath = site.path
    } else {
        pythonPath = root.path
    }

    let eventData = try JSONSerialization.data(withJSONObject: event)
    let eventText = try #require(String(data: eventData, encoding: .utf8))

    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = root.path
    environment["PYTHONPATH"] = pythonPath
    environment["PYTHONNOUSERSITE"] = "1"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["RV_STUB_DIR"] = stubDir.path
    if let confirm {
        environment["RV_ASK_CONFIRM"] = confirm
    } else {
        environment.removeValue(forKey: "RV_ASK_CONFIRM")
    }
    if let secondStub {
        switch secondStub {
        case .stdout(let stdout, let exitCode):
            environment["RV_STUB_STDOUT_2"] = stdout
            environment["RV_STUB_EXIT_2"] = String(exitCode)
        case .missing, .sleep:
            break
        }
    }
    switch stub {
    case .missing:
        break
    case .stdout(let stdout, let exitCode):
        environment["RV_STUB_STDOUT"] = stdout
        environment["RV_STUB_EXIT"] = String(exitCode)
    case .sleep(let seconds):
        environment["RV_STUB_SLEEP"] = String(seconds)
        environment["RV_STUB_EXIT"] = "0"
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", harness.path, adapter.path, eventText]
    process.environment = environment
    process.currentDirectoryURL = root
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "python stderr: \(err) stdout: \(text)")

    let object = try harnessObject(text)
    let mapped = object["result"] as? [String: Any]
    let spawned = FileManager.default.fileExists(
        atPath: stubDir.appendingPathComponent("spawned").path
    )
    let spawnCountText = (
        try? String(
            contentsOf: stubDir.appendingPathComponent("n"),
            encoding: .utf8
        )
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    let spawnCount = Int(spawnCountText ?? "0") ?? 0
    let lastStdin = try? String(
        contentsOf: stubDir.appendingPathComponent("stdin"),
        encoding: .utf8
    )
    return HermesAdapterRun(
        action: mapped?["action"] as? String,
        message: mapped?["message"] as? String,
        spawned: spawned,
        spawnCount: spawnCount,
        lastStdin: lastStdin
    )
}

private func harnessObject(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
