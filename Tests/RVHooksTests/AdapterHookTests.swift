import Foundation
import Testing

private let resetHardReason =
    "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
private let incompleteReason =
    "rv could not finish evaluating this command. Run it in Terminal."

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func adapterTemplate(_ name: String) throws -> String {
    let url = repoRoot().appendingPathComponent("Sources/RVCLI/Resources/hosts/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func harnessURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/adapters/harness.mjs")
}

@Test func piTemplate_registersToolCallAndDisplayOnlyRenderer() throws {
    let source = try adapterTemplate("rv-guard.ts.tmpl")
    #expect(source.contains("pi.on(\"tool_call\""))
    #expect(source.contains("registerMessageRenderer"))
    #expect(source.contains("rv-decision"))
    #expect(source.contains("Why"))
    #expect(source.contains("Cmd"))
    #expect(source.contains("Meta"))
    #expect(source.contains("Next"))
    #expect(source.contains("confirm") == false)
    #expect(source.contains("terminate: true") == false)
    #expect(source.contains("user_bash") == false)
    #expect(source.contains("permission.ask") == false)
    #expect(source.contains("terminalContentWidth") == false)
    #expect(source.contains("function capitalize") == false)
    #expect(source.contains("function buildWidget") == false)
    #expect(source.contains("card.severity") == false)
    #expect(source.contains("card.pack") == false)
    #expect(source.contains("render(width)"))
}

@Test func openCodeTemplate_registersOnlyExecuteBefore() throws {
    let source = try adapterTemplate("rv-guard.js.tmpl")
    #expect(source.contains("\"tool.execute.before\""))
    #expect(source.contains("showToast"))
    #expect(source.contains("RV · Blocked"))
    #expect(source.contains("permission.ask") == false)
    #expect(source.contains("tool: {") == false)
    #expect(source.contains("console.log") == false)
    #expect(source.contains("console.error") == false)
}

@Test func piAdapter_resetHardBlocksWithHostDenyText() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.block == true)
    #expect(result.reason == resetHardReason)
    #expect(result.rendererType == "rv-decision")
    #expect(result.messageCount == 1)
    #expect(result.triggerTurn == false)
    guard case .component(let lines) = result.rendererProbe else {
        Issue.record("expected component renderer, got \(result.rendererProbe)")
        return
    }
    let joined = lines.joined(separator: "\n")
    #expect(joined.contains("RV · Blocked"))
    #expect(joined.contains("Why"))
    #expect(joined.contains("Blocked git reset --hard"))
    #expect(joined.contains("Cmd"))
    #expect(joined.contains("git reset --hard"))
    #expect(joined.contains("Meta"))
    #expect(joined.contains("core.git/reset-hard"))
    #expect(joined.contains("Next"))
    #expect(joined.contains("Run it in Terminal, or rv allow-once."))
    #expect(joined.contains("┏") == false)
    #expect(joined.contains("│") == false)
    #expect(result.cardVariant == "block")
    #expect(result.cardRule == "core.git/reset-hard")
    #expect(result.cardPreview == "git reset --hard")
    #expect(result.cardNext == "Run it in Terminal, or rv allow-once.")
    #expect((result.narrowLines ?? []).count > lines.count)
}

@Test func piAdapter_sendMessageThrowStillBlocks() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1),
        sendMessageThrows: true
    )
    #expect(result.block == true)
    #expect(result.reason == resetHardReason)
}

@Test func piAdapter_allowDoesNotPostDecisionCard() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git status"]],
        stub: .stdout("", exit: 0)
    )
    #expect(result.block == nil)
    #expect(result.messageCount == 0)
    #expect(result.rendererType == "rv-decision")
    #expect(result.rendererProbe == .missing)
}

@Test func piAdapter_nonBashDoesNotSpawn() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "read", "input": ["path": "/tmp/readme"]],
        stub: .stdout("", exit: 0)
    )
    #expect(result.block == nil)
    #expect(result.spawned == false)
}

@Test func openCodeAdapter_resetHardThrowsHostDenyText() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.toastCount == 1)
    #expect(result.toastTitle == "RV · Blocked")
    #expect(result.toastVariant == "error")
    let message = result.toastMessage ?? ""
    #expect(message.contains("Why"))
    #expect(message.contains("Blocked git reset --hard"))
    #expect(message.contains("Cmd"))
    #expect(message.contains("git reset --hard"))
    #expect(message.contains("Meta"))
    #expect(message.contains("core.git/reset-hard"))
    #expect(message.contains("Next"))
    #expect(message.contains("Run it in Terminal, or rv allow-once."))
    #expect(message != resetHardReason)
}

@Test func openCodeAdapter_toastSplitsWrapperCommand() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": wrapperResetHardCommand]],
        stub: .stdout(wrapperResetHardJSON, exit: 1)
    )
    #expect(result.threw == wrapperResetHardReason)
    let message = result.toastMessage ?? ""
    #expect(message.contains("Why"))
    #expect(message.contains("Cmd"))
    #expect(message.contains(wrapperResetHardCommand))
    #expect(message.contains("Meta"))
    #expect(message.contains("core.git/reset-hard"))
    #expect(message.contains("Next"))
    #expect(message.contains("Run it in Terminal, or rv allow-once."))
}

@Test func openCodeAdapter_toastThrowStillBlocks() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1),
        toastThrows: true
    )
    #expect(result.threw == resetHardReason)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_toastTimeoutStillBlocks() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1),
        toastHangs: true,
        toastTimeoutMs: 50
    )
    #expect(result.threw == resetHardReason)
}

@Test func openCodeAdapter_allowDoesNotToast() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git status"]],
        stub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_nonBashDoesNotSpawn() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "read", "args": ["filePath": "/tmp/readme"]],
        stub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawned == false)
}

@Test func adapters_missingRvBlocksWithRvMissing() async throws {
    let pi = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git status"]],
        stub: .missing
    )
    #expect(pi.block == true)
    #expect(pi.reason == "rv missing")

    let openCode = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git status"]],
        stub: .missing
    )
    #expect(openCode.threw == "rv missing")
    #expect(openCode.toastTitle == "RV · Blocked")
    let missingMessage = openCode.toastMessage ?? ""
    #expect(missingMessage.contains("Why"))
    #expect(missingMessage.contains("rv missing"))
    #expect(missingMessage.contains("Cmd"))
}

@Test func adapters_honorDenyJSONRegardlessOfExitIncludingIndeterminate() async throws {
    let denyExitZero = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 0)
    )
    #expect(denyExitZero.block == true)
    #expect(denyExitZero.reason == resetHardReason)

    let indeterminate = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git reset --hard"]],
        stub: .stdout(incompleteJSON, exit: 0)
    )
    #expect(indeterminate.threw == incompleteReason)

    let emptyReason = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"]],
        stub: .stdout("{\"decision\":\"deny\",\"reason\":\"\"}\n", exit: 0)
    )
    #expect(emptyReason.block == true)
    #expect(emptyReason.reason == "")
}

@Test func adapters_startedRvTimeoutOrCrashBlocksWithRvFailed() async throws {
    let crashed = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git status"]],
        stub: .stdout("not-json", exit: 99)
    )
    #expect(crashed.block == true)
    #expect(crashed.reason == "rv failed")

    let timedOut = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git status"]],
        stub: .sleep(seconds: 1),
        timeoutMs: 50
    )
    #expect(timedOut.threw == "rv failed")
}

@Test(arguments: [
    ("pi", "allow"),
    ("opencode", "allow"),
    ("pi", "crash"),
    ("opencode", "crash"),
    ("pi", "timeout"),
    ("opencode", "timeout"),
])
func adapters_mapRvHookResultMatrix(host: String, kind: String) async throws {
    let stub: StubRV
    let timeoutMs: Int?
    switch kind {
    case "allow":
        stub = .stdout("", exit: 0)
        timeoutMs = nil
    case "crash":
        stub = .stdout("not-json", exit: 99)
        timeoutMs = nil
    case "timeout":
        stub = .sleep(seconds: 1)
        timeoutMs = 50
    default:
        Issue.record("unknown matrix kind \(kind)")
        return
    }

    if host == "pi" {
        let result = try await runPiAdapter(
            event: ["toolName": "bash", "input": ["command": "git status"]],
            stub: stub,
            timeoutMs: timeoutMs
        )
        if kind != "timeout" {
            #expect(result.spawned == true, Comment(rawValue: "\(host) \(kind)"))
        }
        if kind == "allow" {
            #expect(result.block == nil, Comment(rawValue: "\(host) \(kind)"))
            #expect(result.reason == nil, Comment(rawValue: "\(host) \(kind)"))
        } else {
            #expect(result.block == true, Comment(rawValue: "\(host) \(kind)"))
            #expect(result.reason == "rv failed", Comment(rawValue: "\(host) \(kind)"))
        }
        return
    }

    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git status"]],
        stub: stub,
        timeoutMs: timeoutMs
    )
    if kind != "timeout" {
        #expect(result.spawned == true, Comment(rawValue: "\(host) \(kind)"))
    }
    if kind == "allow" {
        #expect(result.threw == nil, Comment(rawValue: "\(host) \(kind)"))
        #expect(result.toastCount == 0, Comment(rawValue: "\(host) \(kind)"))
    } else {
        #expect(result.threw == "rv failed", Comment(rawValue: "\(host) \(kind)"))
        #expect(result.toastTitle == "RV · Blocked", Comment(rawValue: "\(host) \(kind)"))
        let failedMessage = result.toastMessage ?? ""
        #expect(failedMessage.contains("Why"), Comment(rawValue: "\(host) \(kind)"))
        #expect(failedMessage.contains("rv failed"), Comment(rawValue: "\(host) \(kind)"))
    }
}

private let resetHardJSON =
    "{\"decision\":\"deny\",\"reason\":\"Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.\",\"rule\":\"core.git/reset-hard\",\"next\":\"Run it in Terminal, or rv allow-once.\"}\n"
private let wrapperResetHardCommand = "echo \"$(git reset --hard)\""
private let wrapperResetHardReason =
    "Blocked echo \"$(git reset --hard)\" (core.git/reset-hard). Run it in Terminal, or rv allow-once."
private let wrapperResetHardJSON =
    "{\"decision\":\"deny\",\"reason\":\"Blocked echo \\\"$(git reset --hard)\\\" (core.git/reset-hard). Run it in Terminal, or rv allow-once.\",\"rule\":\"core.git/reset-hard\",\"next\":\"Run it in Terminal, or rv allow-once.\"}\n"
private let incompleteJSON =
    "{\"decision\":\"deny\",\"reason\":\"rv could not finish evaluating this command. Run it in Terminal.\"}\n"

private enum StubRV {
    case missing
    case stdout(String, exit: Int32)
    case sleep(seconds: Int)
}

private enum RendererProbe: Equatable, Sendable {
    case component(lines: [String])
    case string
    case missing
}

private struct PiAdapterRun {
    var block: Bool?
    var reason: String?
    var spawned: Bool
    var rendererType: String?
    var messageCount: Int
    var triggerTurn: Bool?
    var rendererProbe: RendererProbe
    var narrowLines: [String]?
    var cardVariant: String?
    var cardRule: String?
    var cardPreview: String?
    var cardNext: String?
}

private struct OpenCodeAdapterRun {
    var threw: String?
    var spawned: Bool
    var toastCount: Int
    var toastTitle: String?
    var toastMessage: String?
    var toastVariant: String?
}

private func runPiAdapter(
    event: [String: Any],
    stub: StubRV,
    timeoutMs: Int? = nil,
    sendMessageThrows: Bool = false
) async throws -> PiAdapterRun {
    let payload = try await runAdapter(
        host: "pi",
        event: event,
        stub: stub,
        timeoutMs: timeoutMs,
        sendMessageThrows: sendMessageThrows
    )
    let object = try harnessObject(payload.text)
    let result = object["result"] as? [String: Any]
    let messages = object["messages"] as? [[String: Any]] ?? []
    let firstMessage = messages.first
    let options = firstMessage?["options"] as? [String: Any]
    let message = firstMessage?["message"] as? [String: Any]
    let details = message?["details"] as? [String: Any]
    return PiAdapterRun(
        block: result?["block"] as? Bool,
        reason: result?["reason"] as? String,
        spawned: payload.spawned,
        rendererType: object["rendererType"] as? String,
        messageCount: messages.count,
        triggerTurn: options?["triggerTurn"] as? Bool,
        rendererProbe: rendererProbe(from: object),
        narrowLines: object["narrowLines"] as? [String],
        cardVariant: details?["variant"] as? String,
        cardRule: details?["rule"] as? String,
        cardPreview: details?["preview"] as? String,
        cardNext: details?["nextStep"] as? String
    )
}

private func rendererProbe(from object: [String: Any]) -> RendererProbe {
    switch object["rendererProbe"] as? String {
    case "component":
        return .component(lines: object["lines"] as? [String] ?? [])
    case "string":
        return .string
    default:
        return .missing
    }
}

private func runOpenCodeAdapter(
    event: [String: Any],
    stub: StubRV,
    timeoutMs: Int? = nil,
    toastThrows: Bool = false,
    toastHangs: Bool = false,
    toastTimeoutMs: Int? = nil
) async throws -> OpenCodeAdapterRun {
    let payload = try await runAdapter(
        host: "opencode",
        event: event,
        stub: stub,
        timeoutMs: timeoutMs,
        toastThrows: toastThrows,
        toastHangs: toastHangs,
        toastTimeoutMs: toastTimeoutMs
    )
    let object = try harnessObject(payload.text)
    let toast = firstToast(object)
    return OpenCodeAdapterRun(
        threw: object["threw"] as? String,
        spawned: payload.spawned,
        toastCount: (object["toasts"] as? [Any])?.count ?? 0,
        toastTitle: toast?["title"] as? String,
        toastMessage: toast?["message"] as? String,
        toastVariant: toast?["variant"] as? String
    )
}

private func firstToast(_ object: [String: Any]) -> [String: Any]? {
    let toasts = object["toasts"] as? [[String: Any]] ?? []
    guard let first = toasts.first else { return nil }
    if let body = first["body"] as? [String: Any] {
        return body
    }
    if let properties = first["properties"] as? [String: Any] {
        return properties
    }
    return first
}

private struct AdapterPayload {
    var text: String
    var spawned: Bool
}

private func runAdapter(
    host: String,
    event: [String: Any],
    stub: StubRV,
    timeoutMs: Int?,
    sendMessageThrows: Bool = false,
    toastThrows: Bool = false,
    toastHangs: Bool = false,
    toastTimeoutMs: Int? = nil
) async throws -> AdapterPayload {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-t5-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let templateName = host == "pi" ? "rv-guard.ts.tmpl" : "rv-guard.js.tmpl"
    var source = try adapterTemplate(templateName)
    let rvPath: String
    let stubDir = root.appendingPathComponent("stub", isDirectory: true)
    try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)

    switch stub {
    case .missing:
        rvPath = root.appendingPathComponent("missing-rv").path
    case .stdout, .sleep:
        rvPath = root.appendingPathComponent("rv-stub").path
        let script = """
        #!/bin/sh
        if [ -n "$RV_STUB_DIR" ]; then
          mkdir -p "$RV_STUB_DIR"
          echo spawned > "$RV_STUB_DIR/spawned"
          cat > "$RV_STUB_DIR/stdin"
        fi
        if [ -n "$RV_STUB_SLEEP" ]; then
          sleep "$RV_STUB_SLEEP"
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

    source = source.replacingOccurrences(of: "__RV_BINARY__", with: rvPath)
    if let timeoutMs {
        source = source.replacingOccurrences(
            of: "const RV_HOOK_TIMEOUT_MS = 5000;",
            with: "const RV_HOOK_TIMEOUT_MS = \(timeoutMs);"
        )
    }
    if let toastTimeoutMs {
        source = source.replacingOccurrences(
            of: "const RV_TOAST_TIMEOUT_MS = 1500;",
            with: "const RV_TOAST_TIMEOUT_MS = \(toastTimeoutMs);"
        )
    }
    let adapter = root.appendingPathComponent("adapter.mjs")
    try source.write(to: adapter, atomically: true, encoding: .utf8)

    let eventData = try JSONSerialization.data(withJSONObject: event)
    let eventText = try #require(String(data: eventData, encoding: .utf8))

    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = root.path
    environment["RV_STUB_DIR"] = stubDir.path
    if sendMessageThrows {
        environment["RV_SEND_MESSAGE_THROWS"] = "1"
    }
    if toastThrows {
        environment["RV_TOAST_THROWS"] = "1"
    }
    if toastHangs {
        environment["RV_TOAST_HANGS"] = "1"
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
    process.arguments = [
        "node",
        harnessURL().path,
        host,
        adapter.path,
        eventText,
    ]
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

    let spawned = FileManager.default.fileExists(
        atPath: stubDir.appendingPathComponent("spawned").path
    )
    return AdapterPayload(text: text, spawned: spawned)
}

private func harnessObject(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
