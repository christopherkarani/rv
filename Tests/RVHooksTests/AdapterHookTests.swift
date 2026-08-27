import Foundation
import RVDomain
import RVHooks
import Testing

private let resetHardReason =
    "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
private let incompleteReason =
    "rv could not finish evaluating this command. Run it in Terminal."

private func adapterSource(for host: HookHost, rvPath: String) throws -> String {
    try HostAdapterResources.load(for: host).rendered(rvPath: rvPath)
}

private func harnessURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/adapters/harness.mjs")
}

private func openCodePluginContractURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/adapters/opencode-11818-plugin.mjs")
}

private func runOpenCodePluginContract(_ source: String) async throws -> OpenCodePluginContract {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-tui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = root.appendingPathComponent("rv-guard-tui.js")
    try source.write(to: plugin, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", openCodePluginContractURL().path, plugin.path]
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
    return OpenCodePluginContract(
        serverLoaded: object["serverLoaded"] as? Bool ?? false,
        serverLoadError: object["serverLoadError"] as? String,
        hasServer: object["hasServer"] as? Bool ?? false,
        hasTui: object["hasTui"] as? Bool ?? false,
        dialogTitle: object["dialogTitle"] as? String,
        dialogMessage: object["dialogMessage"] as? String,
        replied: object["replied"] as? String
    )
}

@Test func grokTemplate_bakesRvPathIntoBashMatcher() throws {
    let source = try adapterSource(for: .grok, rvPath: "/opt/rv")
    let object = try JSONSerialization.jsonObject(with: Data(source.utf8))
    let root = try #require(object as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
    let entry = try #require(preToolUse.first)
    #expect(entry["matcher"] as? String == "Bash")
    let commands = try #require(entry["hooks"] as? [[String: Any]])
    #expect(commands.first?["command"] as? String == "/opt/rv hook --host grok")
}

@Test func piTemplate_registersToolCallAndDisplayOnlyRenderer() throws {
    let source = try adapterSource(for: .pi, rvPath: "/opt/rv")
    #expect(source.contains("pi.on(\"tool_call\""))
    #expect(source.contains("registerMessageRenderer"))
    #expect(source.contains("rv-decision"))
    #expect(source.contains("Why"))
    #expect(source.contains("Cmd"))
    #expect(source.contains("Meta"))
    #expect(source.contains("Next"))
    #expect(source.contains("ui?.confirm"))
    #expect(source.contains("hostAsk: \"spend\""))
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

@Test func openCodeTemplate_registersExecuteBeforeAndShellEnv() throws {
    let source = try adapterSource(for: .opencode, rvPath: "/opt/rv")
    #expect(source.contains("\"tool.execute.before\""))
    #expect(source.contains("\"shell.env\""))
    #expect(source.contains("session.shell"))
    #expect(source.contains("showToast"))
    #expect(source.contains("RV · Blocked"))
    #expect(source.contains("hostAsk: \"spend\""))
    #expect(source.contains("onResolution"))
    #expect(source.contains("session.permission.create"))
    #expect(source.contains("permission.ask") == false)
    #expect(source.contains("tool: {") == false)
    #expect(source.contains("console.log") == false)
    #expect(source.contains("console.error") == false)
    let tui = try HostAdapterResources.loadOpenCodeTuiPlugin()
    #expect(tui.contains("DialogConfirm"))
    #expect(tui.contains("RV · Ask"))
    #expect(tui.contains("permission.ask") == false)
    #expect(tui.contains("server:"))
    #expect(source.contains("pollOfficialPermissionReply"))
    #expect(source.contains("RV_ASK_TIMEOUT_MS"))
    #expect(source.contains("attempt < 40") == false)
}

@Test func openCodeTuiPlugin_defaultExportsServerAndLoadsOnOpenCode11818() async throws {
    let probe = try await runOpenCodePluginContract(try HostAdapterResources.loadOpenCodeTuiPlugin())
    #expect(probe.hasServer == true)
    #expect(probe.hasTui == false)
    #expect(probe.serverLoaded == true)
    #expect(probe.serverLoadError == nil)
    #expect(probe.dialogTitle == "RV · Ask")
    #expect(probe.dialogMessage?.contains("git reset --hard") == true)
    #expect(probe.replied == "once")
}

@Test func openClawTemplate_registersBeforeToolCallExecAndBlocks() throws {
    let source = try adapterSource(for: .openclaw, rvPath: "/opt/rv")
    #expect(source.contains("before_tool_call"))
    #expect(source.contains("matcher: [\"exec\"]"))
    #expect(source.contains("block: true"))
    #expect(source.contains("blockReason"))
    #expect(source.contains("hook\", \"--host\", host"))
    #expect(source.contains("\"openclaw\""))
    #expect(source.contains("requireApproval") == false)
    #expect(source.contains("permission.ask") == false)
    #expect(source.contains("RV_BYPASS") == false)
}

@Test func hermesTemplate_registersPreToolCallTerminalAndBlocks() throws {
    let source = try adapterSource(for: .hermes, rvPath: "/opt/rv")
    #expect(source.contains("pre_tool_call"))
    #expect(source.contains("**kwargs"))
    #expect(source.contains("tool_name != \"terminal\""))
    #expect(source.contains("\"action\": \"block\""))
    #expect(source.contains("\"hermes\""))
    #expect(source.contains("RV_BINARY = \"/opt/rv\""))
    #expect(source.contains("\"action\": \"approve\"") == false)
    #expect(source.contains("permission.ask") == false)
    #expect(source.contains("RV_BYPASS") == false)
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

@Test func piAdapter_confirmYesSpendsThenAllows() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"], "cwd": "/tmp/ws"],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.messageCount == 0)
}

@Test func piAdapter_confirmYesFailedSpendDoesNotRunTool() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"], "cwd": "/tmp/ws"],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.block == true)
    #expect(result.reason == resetHardReason)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func piAdapter_confirmYesMissingSpendDoesNotRunTool() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"], "cwd": "/tmp/ws"],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 2)
}

@Test func piAdapter_hasUIFalseDoesNotSpend() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"], "cwd": "/tmp/ws"],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        hasUI: false,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == true)
    #expect(result.spawnCount == 1)
}

@Test func piAdapter_unlockableDenyConfirmYesSpendsThenAllows() async throws {
    let result = try await runPiAdapter(
        event: ["toolName": "bash", "input": ["command": "git reset --hard"], "cwd": "/tmp/ws"],
        stub: .stdout(resetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.block == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func openCodeAdapter_sessionShellResetHardThrowsHostDenyText() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "session.shell", "args": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawned == true)
}

@Test func openCodeAdapter_sessionShellAskJSONDoesNotAllow() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "session.shell", "args": ["command": "git reset --hard"]],
        stub: .stdout(askResetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.toastCount == 1)
    #expect(result.spawnCount == 1)
}

@Test func openCodeAdapter_sessionShellConfirmYesSpendsThenAllows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "tool": "session.shell",
            "cwd": "/tmp/ws",
            "args": ["command": "git reset --hard"],
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_sessionShellFailedSpendDoesNotRunTool() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "tool": "session.shell",
            "cwd": "/tmp/ws",
            "args": ["command": "git reset --hard"],
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func openCodeAdapter_sessionShellEnvResetHardThrows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
        ],
        stub: .stdout(resetHardJSON, exit: 1),
        sessionMessages: tuiShellMessages(callID: "call_1", command: "git reset --hard")
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawned == true)
}

@Test func openCodeAdapter_sessionShellEnvAskDoesNotAllow() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 1)
}

@Test func openCodeAdapter_sessionShellEnvOfficialConfirmSpendsThenAllows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "once",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.lastStdin?.contains("git reset --hard") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_sessionShellEnvOfficialConfirmRejectDoesNotAllow() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "reject",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func openCodeAdapter_sessionShellEnvOfficialFetchConfirmSpendsThenAllows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "fetch-once",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.lastStdin?.contains("git reset --hard") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_sessionShellEnvOfficialCreateAllowIsNotAPermit() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "allow",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func openCodeAdapter_sessionShellEnvOfficialCreateHappensWhenSubscribeThrows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "once",
        permissionSubscribe: "throw",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.permissionCreates == 1)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_sessionShellEnvOfficialCreateHappensWhenSubscribeMissing() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "once",
        permissionSubscribe: "missing",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.permissionCreates == 1)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func openCodeAdapter_sessionShellEnvOfficialMissingConfirmStillThrowsWhenSubscribeThrows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "absent",
        permissionSubscribe: "throw",
        askTimeoutMs: 400,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.permissionCreates == 1)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func openCodeAdapter_sessionShellEnvOfficialPollSurvivesFirstHTTPMiss() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "miss-then-once",
        permissionSubscribe: "throw",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.permissionCreates == 1)
    #expect(result.permissionGets >= 2)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_sessionShellEnvOfficialPollWaitsForLateTUIYes() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "late-once",
        permissionSubscribe: "missing",
        permissionLateMs: 1500,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.permissionCreates == 1)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.lastStdin?.contains("git reset --hard") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_sessionShellEnvOfficialPollLateRejectStillThrows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        permissionReply: "miss-then-reject",
        permissionSubscribe: "throw",
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.permissionCreates == 1)
    #expect(result.permissionGets >= 2)
    #expect(result.spawnCount == 1)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
}

@Test func openCodeAdapter_sessionShellEnvConfirmSpendsThenAllows() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func openCodeAdapter_sessionShellEnvFailedSpendDoesNotRunTool() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_1",
            "command": "git reset --hard",
        ],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 2)
}

@Test func openCodeAdapter_sessionShellEnvMissingCommandDoesNotAllow() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_missing",
        ],
        stub: .stdout("", exit: 0)
    )
    #expect(result.threw == missingShellCommandReason)
    #expect(result.spawned == false)
}

@Test func openCodeAdapter_sessionShellEnvPriorAllowLastMatchDoesNotPermitResetHard() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_new",
        ],
        stub: .stdout("", exit: 0),
        sessionMessages: tuiShellMessages(callID: "call_old", command: "git status")
    )
    #expect(result.threw == missingShellCommandReason)
    #expect(result.spawned == false)
    #expect(result.lastStdin == nil)
}

@Test func openCodeAdapter_sessionShellEnvMissingCallIDDoesNotLastMatchAllow() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
        ],
        stub: .stdout("", exit: 0),
        sessionMessages: tuiShellMessages(callID: "call_old", command: "git status")
    )
    #expect(result.threw == missingShellCommandReason)
    #expect(result.spawned == false)
}

@Test func openCodeAdapter_sessionShellEnvNonShellToolCommandIsNotAPermit() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_new",
        ],
        stub: .stdout("", exit: 0),
        sessionMessages: tuiShellMessages(
            parts: [tuiShellPart(callID: "call_new", command: "git status", tool: "read")]
        )
    )
    #expect(result.threw == missingShellCommandReason)
    #expect(result.spawned == false)
}

@Test func openCodeAdapter_sessionShellEnvUsesThisCallIDNotPriorAllow() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "hook": "shell.env",
            "cwd": "/tmp/ws",
            "sessionID": "ses_1",
            "callID": "call_new",
        ],
        stub: .stdout(resetHardJSON, exit: 1),
        sessionMessages: tuiShellMessages(
            parts: [
                tuiShellPart(callID: "call_old", command: "git status"),
                tuiShellPart(callID: "call_new", command: "git reset --hard"),
            ]
        )
    )
    #expect(result.threw == resetHardReason)
    #expect(result.lastStdin?.contains("git reset --hard") == true)
    #expect(result.lastStdin?.contains("git status") == false)
}

@Test func openCodeAdapter_sessionShellEnvPriorGatedAllowDoesNotPermitNewCall() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "steps": [
                [
                    "hook": "shell.env",
                    "cwd": "/tmp/ws",
                    "sessionID": "ses_1",
                    "callID": "call_old",
                    "command": "git status",
                ],
                [
                    "hook": "shell.env",
                    "cwd": "/tmp/ws",
                    "sessionID": "ses_1",
                    "callID": "call_new",
                ],
            ]
        ],
        stub: .stdout("", exit: 0),
        sessionMessages: tuiShellMessages(callID: "call_old", command: "git status")
    )
    #expect(result.threw == missingShellCommandReason)
    #expect(result.spawnCount == 1)
}

@Test func openCodeAdapter_bashThenShellEnvDoesNotSilentAllowResetHard() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "steps": [
                [
                    "tool": "bash",
                    "callID": "c1",
                    "args": ["command": "git reset --hard"],
                ],
                [
                    "hook": "shell.env",
                    "callID": "c1",
                    "cwd": "/tmp/ws",
                ],
            ]
        ],
        stub: .stdout(askResetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 1)
}

@Test func openCodeAdapter_allowedBashDoesNotFailClosedOnFollowUpShellEnv() async throws {
    let result = try await runOpenCodeAdapter(
        event: [
            "steps": [
                [
                    "tool": "bash",
                    "callID": "c1",
                    "args": ["command": "git status"],
                ],
                [
                    "hook": "shell.env",
                    "callID": "c1",
                    "cwd": "/tmp/ws",
                ],
            ]
        ],
        stub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
}

@Test func openCodeAdapter_askJSONDoesNotAllow() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git reset --hard"]],
        stub: .stdout(askResetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.toastCount == 1)
    #expect(result.spawnCount == 1)
}

@Test func openCodeAdapter_confirmYesSpendsThenAllows() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "cwd": "/tmp/ws", "args": ["command": "git reset --hard"]],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_resolutionSpendsThenAllows() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "cwd": "/tmp/ws", "args": ["command": "git reset --hard"]],
        stub: .stdout(askResetHardJSON, exit: 1),
        resolutionAllow: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
    #expect(result.toastCount == 0)
}

@Test func openCodeAdapter_confirmYesFailedSpendDoesNotRunTool() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "cwd": "/tmp/ws", "args": ["command": "git reset --hard"]],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout(resetHardJSON, exit: 1)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
}

@Test func openCodeAdapter_confirmYesMissingSpendDoesNotRunTool() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "cwd": "/tmp/ws", "args": ["command": "git reset --hard"]],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 2)
}

@Test func openCodeAdapter_hasUIFalseDoesNotSpend() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "cwd": "/tmp/ws", "args": ["command": "git reset --hard"]],
        stub: .stdout(askResetHardJSON, exit: 1),
        confirmYes: true,
        hasUI: false,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == resetHardReason)
    #expect(result.spawnCount == 1)
}

@Test func openCodeAdapter_unlockableDenyConfirmYesSpendsThenAllows() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "cwd": "/tmp/ws", "args": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1),
        confirmYes: true,
        secondStub: .stdout("", exit: 0)
    )
    #expect(result.threw == nil)
    #expect(result.spawnCount == 2)
    #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == true)
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

@Test func openCodeAdapter_legacyClientToastsViaWrappedBody() async throws {
    let result = try await runOpenCodeAdapter(
        event: ["tool": "bash", "args": ["command": "git reset --hard"]],
        stub: .stdout(resetHardJSON, exit: 1),
        legacyClient: true
    )
    #expect(result.threw == resetHardReason)
    #expect(result.toastCount == 1)
    #expect(result.toastTitle == "RV · Blocked")
    #expect(result.toastVariant == "error")
    let message = result.toastMessage ?? ""
    #expect(message.contains("Blocked git reset --hard"))
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

private let missingShellCommandReason =
    "rv received a shell hook with no command text and blocked the command. Run it in Terminal."
private let resetHardJSON =
    "{\"decision\":\"deny\",\"reason\":\"Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.\",\"rule\":\"core.git/reset-hard\",\"next\":\"Run it in Terminal, or rv allow-once.\"}\n"
private let askResetHardJSON =
    "{\"decision\":\"ask\",\"reason\":\"Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.\",\"continuation\":\"hostNative\",\"rule\":\"core.git/reset-hard\",\"next\":\"Run it in Terminal, or rv allow-once.\"}\n"
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
    var spawnCount: Int
    var lastStdin: String?
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
    var spawnCount: Int
    var lastStdin: String?
    var toastCount: Int
    var toastTitle: String?
    var toastMessage: String?
    var toastVariant: String?
    var permissionCreates: Int
    var permissionGets: Int
}

private struct OpenCodePluginContract {
    var serverLoaded: Bool
    var serverLoadError: String?
    var hasServer: Bool
    var hasTui: Bool
    var dialogTitle: String?
    var dialogMessage: String?
    var replied: String?
}

private func runPiAdapter(
    event: [String: Any],
    stub: StubRV,
    timeoutMs: Int? = nil,
    sendMessageThrows: Bool = false,
    confirmYes: Bool = false,
    hasUI: Bool = true,
    secondStub: StubRV? = nil
) async throws -> PiAdapterRun {
    let payload = try await runAdapter(
        host: .pi,
        event: event,
        stub: stub,
        timeoutMs: timeoutMs,
        sendMessageThrows: sendMessageThrows,
        confirmYes: confirmYes,
        hasUI: hasUI,
        secondStub: secondStub
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
        spawnCount: payload.spawnCount,
        lastStdin: payload.lastStdin,
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

private func tuiShellPart(callID: String, command: String, tool: String = "bash") -> [String: Any] {
    [
        "type": "tool",
        "tool": tool,
        "callID": callID,
        "state": ["input": ["command": command]],
    ]
}

private func tuiShellMessages(parts: [[String: Any]]) -> [String: Any] {
    ["data": [["parts": parts]]]
}

private func tuiShellMessages(callID: String, command: String) -> [String: Any] {
    tuiShellMessages(parts: [tuiShellPart(callID: callID, command: command)])
}

private func runOpenCodeAdapter(
    event: [String: Any],
    stub: StubRV,
    timeoutMs: Int? = nil,
    toastThrows: Bool = false,
    toastHangs: Bool = false,
    toastTimeoutMs: Int? = nil,
    legacyClient: Bool = false,
    confirmYes: Bool = false,
    hasUI: Bool = true,
    resolutionAllow: Bool = false,
    permissionReply: String? = nil,
    permissionSubscribe: String? = nil,
    permissionLateMs: Int? = nil,
    askTimeoutMs: Int? = nil,
    secondStub: StubRV? = nil,
    sessionMessages: [String: Any]? = nil
) async throws -> OpenCodeAdapterRun {
    let payload = try await runAdapter(
        host: .opencode,
        event: event,
        stub: stub,
        timeoutMs: timeoutMs,
        toastThrows: toastThrows,
        toastHangs: toastHangs,
        toastTimeoutMs: toastTimeoutMs,
        legacyClient: legacyClient,
        confirmYes: confirmYes,
        hasUI: hasUI,
        resolutionAllow: resolutionAllow,
        permissionReply: permissionReply,
        permissionSubscribe: permissionSubscribe,
        permissionLateMs: permissionLateMs,
        askTimeoutMs: askTimeoutMs,
        secondStub: secondStub,
        sessionMessages: sessionMessages
    )
    let object = try harnessObject(payload.text)
    let toast = firstToast(object)
    return OpenCodeAdapterRun(
        threw: object["threw"] as? String,
        spawned: payload.spawned,
        spawnCount: payload.spawnCount,
        lastStdin: payload.lastStdin,
        toastCount: (object["toasts"] as? [Any])?.count ?? 0,
        toastTitle: toast?["title"] as? String,
        toastMessage: toast?["message"] as? String,
        toastVariant: toast?["variant"] as? String,
        permissionCreates: object["permissionCreates"] as? Int ?? 0,
        permissionGets: object["permissionGets"] as? Int ?? 0
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
    var spawnCount: Int
    var lastStdin: String?
}

private func runAdapter(
    host: HookHost,
    event: [String: Any],
    stub: StubRV,
    timeoutMs: Int?,
    sendMessageThrows: Bool = false,
    toastThrows: Bool = false,
    toastHangs: Bool = false,
    toastTimeoutMs: Int? = nil,
    legacyClient: Bool = false,
    confirmYes: Bool = false,
    hasUI: Bool = true,
    resolutionAllow: Bool = false,
    permissionReply: String? = nil,
    permissionSubscribe: String? = nil,
    permissionLateMs: Int? = nil,
    askTimeoutMs: Int? = nil,
    secondStub: StubRV? = nil,
    sessionMessages: [String: Any]? = nil
) async throws -> AdapterPayload {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-t5-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

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

    var source = try adapterSource(for: host, rvPath: rvPath)
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
    if let askTimeoutMs {
        source = source.replacingOccurrences(
            of: "const RV_ASK_TIMEOUT_MS = 120000;",
            with: "const RV_ASK_TIMEOUT_MS = \(askTimeoutMs);"
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
    if legacyClient {
        environment["RV_TOAST_LEGACY_CLIENT"] = "1"
    }
    if confirmYes {
        environment["RV_CONFIRM_YES"] = "1"
    }
    if hasUI == false {
        environment["RV_HAS_UI"] = "0"
    }
    if resolutionAllow {
        environment["RV_RESOLUTION_ALLOW"] = "1"
    }
    if let permissionReply {
        environment["RV_PERMISSION_REPLY"] = permissionReply
    }
    if let permissionSubscribe {
        environment["RV_PERMISSION_SUBSCRIBE"] = permissionSubscribe
    }
    if let permissionLateMs {
        environment["RV_PERMISSION_LATE_MS"] = String(permissionLateMs)
    }
    if let sessionMessages {
        let data = try JSONSerialization.data(withJSONObject: sessionMessages)
        environment["RV_SESSION_MESSAGES"] = try #require(String(data: data, encoding: .utf8))
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
    process.arguments = [
        "node",
        harnessURL().path,
        host.rawValue,
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
    return AdapterPayload(
        text: text,
        spawned: spawned,
        spawnCount: spawnCount,
        lastStdin: lastStdin
    )
}

private func harnessObject(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
