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
        "toolName": "exec",
        "params": [
            "command": "git reset --hard",
            "workdir": "/tmp/ws",
        ],
        "cwd": "/tmp/ws",
        "sessionId": "sess_1",
        "toolKind": "exec",
    ]
}

@Test func openClawHostAskAdapter_sourceIsWaitThenSpendNeverRequireApproval() throws {
    let source = try adapterSource(for: .openclaw, rvPath: "/opt/rv")
    #expect(source.contains("before_tool_call"))
    #expect(source.contains("hostAsk"))
    #expect(source.contains("spend"))
    #expect(source.contains("RV_ASK_CONFIRM"))
    #expect(source.contains("plugin.approval.request"))
    #expect(source.contains("plugin.approval.waitDecision"))
    #expect(source.contains("allow-once"))
    #expect(source.contains("requireApproval") == false)
    #expect(source.contains("allow-always") == false)
    #expect(source.contains("RV_BYPASS") == false)
}

@Test func openClawHostAskAdapter_confirmYesSpendsThenAllows() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "yes",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block != true)
    #expect(result.blockReason == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.lastStdin?.contains("git reset --hard") == true)
    #expect(result.gatewayCalls.isEmpty)
}

@Test func openClawHostAskAdapter_confirmYesFailedSpendDoesNotRunTool() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "yes",
        secondStub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.block == true)
    #expect(result.blockReason == resetHardReason)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func openClawHostAskAdapter_confirmYesMissingSpendDoesNotRunTool() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "yes"
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 2)
}

@Test func openClawHostAskAdapter_confirmNoDoesNotSpend() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        confirm: "no",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.blockReason == resetHardAskReason)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func openClawHostAskAdapter_missingConfirmWithoutGatewayDoesNotSpend() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        gatewayAvailable: false,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    #expect(result.gatewayCalls.isEmpty)
}

@Test func openClawHostAskAdapter_gatewayAllowOnceSpendsThenAllows() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        gatewayDecision: "allow-once",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block != true)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.gatewayCalls.contains("plugin.approval.request"))
    #expect(result.gatewayCalls.contains("plugin.approval.waitDecision"))
    #expect(result.requestedAllowAlways == false)
}

@Test func openClawHostAskAdapter_gatewayDenyDoesNotSpend() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        gatewayDecision: "deny",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.blockReason == resetHardAskReason)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func openClawHostAskAdapter_gatewayAllowAlwaysIsNotAPermit() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        gatewayDecision: "allow-always",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func openClawHostAskAdapter_gatewayTimeoutDoesNotSpend() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        gatewayTimeout: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 1)
}

@Test func openClawHostAskAdapter_gatewayThrowDoesNotSpend() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        gatewayThrow: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 1)
}

@Test func openClawHostAskAdapter_noRouteDoesNotSpend() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(askResetHardJSON, exit: 1),
        gatewayNoRoute: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 1)
}

@Test func openClawHostAskAdapter_denyJSONDoesNotPause() async throws {
    let result = try await runOpenClawAdapter(
        event: resetHardEvent(),
        stub: .stdout(resetHardJSON, exit: 1),
        confirm: "yes",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.blockReason == resetHardReason)
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

private struct OpenClawAdapterRun {
    var block: Bool?
    var blockReason: String?
    var spawnCount: Int
    var lastStdin: String?
    var gatewayCalls: [String]
    var requestedAllowAlways: Bool
}

private func runOpenClawAdapter(
    event: [String: Any],
    stub: StubRV,
    confirm: String? = nil,
    gatewayAvailable: Bool = true,
    gatewayDecision: String? = nil,
    gatewayTimeout: Bool = false,
    gatewayThrow: Bool = false,
    gatewayNoRoute: Bool = false,
    secondStub: StubRV? = nil
) async throws -> OpenClawAdapterRun {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-openclaw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stubDir = root.appendingPathComponent("stub", isDirectory: true)
    try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
    try writeOpenClawSDKStub(in: root)

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

    let source = try adapterSource(for: .openclaw, rvPath: rvPath)
    let adapter = root.appendingPathComponent("index.js")
    try source.write(to: adapter, atomically: true, encoding: .utf8)

    let eventData = try JSONSerialization.data(withJSONObject: event)
    let eventText = try #require(String(data: eventData, encoding: .utf8))

    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = root.path
    environment["RV_STUB_DIR"] = stubDir.path
    environment["RV_GATEWAY_AVAILABLE"] = gatewayAvailable ? "1" : "0"
    if let confirm {
        environment["RV_ASK_CONFIRM"] = confirm
    } else {
        environment.removeValue(forKey: "RV_ASK_CONFIRM")
    }
    if let gatewayDecision {
        environment["RV_GATEWAY_DECISION"] = gatewayDecision
    }
    if gatewayTimeout {
        environment["RV_GATEWAY_TIMEOUT"] = "1"
    }
    if gatewayThrow {
        environment["RV_GATEWAY_THROW"] = "1"
    }
    if gatewayNoRoute {
        environment["RV_GATEWAY_NO_ROUTE"] = "1"
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
    process.arguments = ["node", harnessURL().path, adapter.path, eventText]
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
    #expect(process.terminationStatus == 0, "node stderr: \(err) stdout: \(text)")

    let object = try harnessObject(text)
    let mapped = object["result"] as? [String: Any]
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
    let calls = object["gatewayCalls"] as? [[String: Any]] ?? []
    let methods = calls.compactMap { $0["method"] as? String }
    let requestedAllowAlways = calls.contains { call in
        let params = call["params"] as? [String: Any]
        let allowed = params?["allowedDecisions"] as? [String] ?? []
        return allowed.contains("allow-always")
    }
    return OpenClawAdapterRun(
        block: mapped?["block"] as? Bool,
        blockReason: mapped?["blockReason"] as? String,
        spawnCount: spawnCount,
        lastStdin: lastStdin,
        gatewayCalls: methods,
        requestedAllowAlways: requestedAllowAlways
    )
}

private func writeOpenClawSDKStub(in root: URL) throws {
    let sdk = root
        .appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent("openclaw", isDirectory: true)
        .appendingPathComponent("plugin-sdk", isDirectory: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    let package = """
    {"name":"openclaw","type":"module","exports":{"./plugin-sdk/plugin-entry":"./plugin-sdk/plugin-entry.js"}}
    """
    try package.write(
        to: sdk.deletingLastPathComponent().appendingPathComponent("package.json"),
        atomically: true,
        encoding: .utf8
    )
    try """
    export function definePluginEntry(definition) {
      return definition;
    }
    """.write(
        to: sdk.appendingPathComponent("plugin-entry.js"),
        atomically: true,
        encoding: .utf8
    )
}

private func harnessURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/adapters/harness-openclaw.mjs")
}

private func harnessObject(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
