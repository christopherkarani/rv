import Foundation
import RVDomain
import RVHooks
import Testing

/// Claude PreToolUse wrapper: confirm then spend. Never leftover `permissionDecision:ask`.
struct ClaudeAdapterHookTests {
    @Test func template_bakesRvAndNeverEmitsPermissionDecisionAsk() throws {
        let source = try adapterSource(rvPath: "/opt/rv")
        #expect(source.contains("PreToolUse"))
        #expect(source.contains("\"Bash\""))
        #expect(source.contains("\"Read\""))
        #expect(source.contains("\"Edit\""))
        #expect(source.contains("\"Write\""))
        #expect(source.contains("\"claude\""))
        #expect(source.contains("RV_BINARY = \"/opt/rv\""))
        #expect(source.contains("hostAsk") == false)
        #expect(source.contains("spend") == false)
        #expect(source.contains("RV_ASK_CONFIRM") == false)
        #expect(source.contains("osascript") == false)
        #expect(source.contains("display dialog") == false)
        #expect(source.contains("__RV_BINARY__") == false)
        #expect(source.contains("permissionDecision\":\"ask\"") == false)
        #expect(source.contains("permissionDecision': 'ask'") == false)
        #expect(source.contains("\"permissionDecision\": \"ask\"") == false)
        #expect(source.contains("RV_BYPASS") == false)
    }

    @Test func confirmYesIgnored_legacyAskBlocks() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (askJSON, 0),
            spend: ("", 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    }

    @Test func confirmYesIgnored_askExitTwoStillBlocks() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (askJSON, 2),
            spend: ("", 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    }

    @Test func confirmNo_deniesWithoutSpend() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (askJSON, 0),
            spend: ("", 0),
            confirm: "no"
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    }

    @Test func missingConfirm_deniesWithoutSpend() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (askJSON, 0),
            spend: ("", 0),
            confirm: ""
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    }

    @Test func confirmYesIgnored_failedSpendStubUnusedAskBlocks() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (askJSON, 0),
            spend: (claudeDenyJSON(reason: resetHardReason), 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    }

    @Test func confirmYesIgnored_secondAskStubUnusedBlocksOnce() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (askJSON, 0),
            spend: (askJSON, 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
    }

    @Test func confirmYesIgnored_nonJSONSpendStubUnusedBlocks() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (askJSON, 0),
            spend: ("not-json\n", 1),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
    }

    @Test func firstCallClaudeDeny_passesThroughWithoutConfirm() async throws {
        let deny = claudeDenyJSON(reason: resetHardReason)
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (deny, 0),
            spend: ("", 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: resetHardReason)
        #expect(result.spawnCount == 1)
        #expect(result.stdout.contains(resetHardReason))
    }

    @Test func firstCallProductionRichDeny_reencodesDocumentedKeysOnly() async throws {
        let richDeny = try claudeAdapterFixture("deny-git-reset-hard.out")
        #expect(richDeny.contains("\"ruleId\""))
        #expect(richDeny.contains("\"packId\""))
        #expect(richDeny.contains("\"severity\""))
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (richDeny, 0),
            spend: ("", 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: resetHardReason)
        #expect(result.spawnCount == 1)
        #expect(result.stdout.contains("ruleId") == false)
        #expect(result.stdout.contains("packId") == false)
        #expect(result.stdout.contains("severity") == false)
    }

    @Test func firstCallEmptyAllow_isEmptyStdoutExitZero() async throws {
        let result = try await runClaudeWrapper(
            event: [
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": ["command": "git status"],
            ],
            first: ("", 0),
            confirm: "yes"
        )
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("permissionDecision") == false)
        #expect(result.spawnCount == 1)
    }

    @Test func missingRv_deniesWithDocumentedFieldsOnly() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            stub: .missing,
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: "rv missing")
        #expect(result.spawnCount == 0)
    }

    @Test func leftoverPermissionDecisionAskFromRv_isNotForwarded() async throws {
        let leftover = """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"once?"}}\n
        """
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (leftover, 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: "once?")
        #expect(result.spawnCount == 1)
    }

    @Test(arguments: ["Read", "Edit", "Write"])
    func fileToolMissingRv_denies(_ tool: String) async throws {
        let result = try await runClaudeWrapper(
            event: fileToolEvent(tool),
            stub: .missing,
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: "rv missing")
        #expect(result.spawnCount == 0)
    }

    @Test(arguments: ["Read", "Edit", "Write"])
    func fileToolDenyJSON_deniesWithoutConfirm(_ tool: String) async throws {
        let deny = claudeDenyJSON(reason: resetHardReason)
        let result = try await runClaudeWrapper(
            event: fileToolEvent(tool),
            first: (deny, 0),
            spend: (askJSON, 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: resetHardReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
        #expect(result.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    }

    @Test func fileToolLeftoverAsk_isDenyNotPermit() async throws {
        let leftover = """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"once?"}}\n
        """
        let result = try await runClaudeWrapper(
            event: fileToolEvent("Read"),
            first: (leftover, 0),
            spend: ("", 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: "once?")
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    }

    @Test func fileToolDecisionAsk_isDenyNotPermit() async throws {
        let result = try await runClaudeWrapper(
            event: fileToolEvent("Read"),
            first: (askJSON, 0),
            spend: ("", 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: askReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastStdin?.contains("\"hostAsk\":\"spend\"") == false)
    }

    @Test(arguments: ["Grep", "Glob", "NotebookEdit", "MultiEdit"])
    func searchAndEditToolsMissingRv_block(_ tool: String) async throws {
        let result = try await runClaudeWrapper(
            event: [
                "hook_event_name": "PreToolUse",
                "tool_name": tool,
                "cwd": "/tmp/ws",
                "tool_input": ["path": "/tmp/ws/.env"],
            ],
            stub: .missing,
            confirm: "yes"
        )
        #expect(result.stdout.contains("\"permissionDecision\":\"deny\""))
        #expect(result.exitCode == 0)
    }

    @Test(arguments: ["TodoWrite", "WebFetch"])
    func foreignToolMissingRv_allows(_ tool: String) async throws {
        let result = try await runClaudeWrapper(
            event: [
                "hook_event_name": "PreToolUse",
                "tool_name": tool,
                "cwd": "/tmp/ws",
                "tool_input": ["path": "/tmp/ws/.env"],
            ],
            stub: .missing,
            confirm: "yes"
        )
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("permissionDecision") == false)
        #expect(result.spawnCount == 0)
    }

    // MARK: failure classes — each names its cause; none emits ask or allows.

    @Test(arguments: [cUnreachableReason, cTimeoutReason])
    func daemonDownAsk_deniesWithTheCHookReason(_ reason: String) async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (cDownAskJSON(reason: reason), 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: reason)
        #expect(result.spawnCount == 1)
    }

    @Test(arguments: ["Bash", "Read"])
    func daemonDownAskWithoutReason_deniesAsDaemonDown(_ tool: String) async throws {
        let bare = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}\n"
        let result = try await runClaudeWrapper(
            event: tool == "Bash" ? resetHardEvent() : fileToolEvent(tool),
            first: (bare, 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: shimDaemonDownReason)
    }

    @Test func shimTimeout_deniesWithItsOwnReason() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            stub: .calls(first: ("", 0), spend: nil),
            confirm: "yes",
            sleepSeconds: 5,
            shimTimeoutSeconds: 1
        )
        try expectClaudeDeny(result, reason: shimTimeoutReason(seconds: 1))
    }

    @Test func shimTimeoutReason_namesTheShippedBudget() throws {
        let source = try adapterSource(rvPath: "/opt/rv")
        #expect(source.contains("RV_HOOK_TIMEOUT_S = 15\n"))
        #expect(source.contains("did not finish within {RV_HOOK_TIMEOUT_S} s"))
    }

    @Test(arguments: [Int32(1), Int32(70)])
    func nonZeroExitWithoutOutput_deniesWithExitStatus(_ code: Int32) async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: ("", code),
            confirm: "yes"
        )
        try expectClaudeDeny(
            result,
            reason: "RV hook exited with status \(code) without a decision. Run `rv doctor`; `rv setup` repairs the install."
        )
    }

    @Test func killedBySignal_deniesWithTheSignal() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            stub: .calls(first: ("", 0), spend: nil),
            confirm: "yes",
            killSignal: 9
        )
        try expectClaudeDeny(
            result,
            reason: "RV hook was killed by signal 9 without a decision. Run `rv doctor`; `rv setup` repairs the install."
        )
    }

    @Test(arguments: ["not-json\n", "[1,2]\n", "{\"decision\":\"maybe\"}\n"])
    func unreadableReply_deniesAsBadReply(_ stdout: String) async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (stdout, 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: shimBadReplyReason)
    }

    @Test func failureReasons_areDistinct() {
        let reasons: Set<String> = [
            cUnreachableReason, cTimeoutReason, shimDaemonDownReason,
            shimTimeoutReason(seconds: 15), shimBadReplyReason, "rv missing",
        ]
        #expect(reasons.count == 6)
    }
}

/// `kUnreachableMessage` / `kTimeoutMessage` in `Sources/rv-c/hook_fallback.c`.
private let cUnreachableReason =
    "RV daemon is not reachable (dev.rv.evaluate). Run `rv doctor`; `rv setup` repairs the service."
private let cTimeoutReason =
    "RV daemon did not answer in time. Retry; if it persists run `rv doctor`."
private let shimDaemonDownReason =
    "RV daemon is not reachable or did not answer in time. Run `rv doctor`."
private let shimBadReplyReason =
    "RV hook sent an unreadable reply (version skew after an upgrade?). Run `rv doctor`; `rv setup` repairs the install."

private func shimTimeoutReason(seconds: Int) -> String {
    "RV hook did not finish within \(seconds) s (rvd busy or hung?). Retry; if it persists run `rv doctor`."
}

/// The C hook's `RV_HOOK_WHEN_DOWN=ask` reply for Claude (`render_ask`).
private func cDownAskJSON(reason: String) -> String {
    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(reason)\"},\"systemMessage\":\"\(reason)\"}\n"
}

private func resetHardEvent() -> [String: Any] {
    [
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "cwd": "/tmp/ws",
        "tool_input": ["command": "git reset --hard"],
    ]
}

private func fileToolEvent(_ tool: String) -> [String: Any] {
    [
        "hook_event_name": "PreToolUse",
        "tool_name": tool,
        "cwd": "/tmp/ws",
        "tool_input": ["file_path": "/tmp/ws/.env"],
    ]
}

private let askReason =
    "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
private let askJSON =
    "{\"decision\":\"ask\",\"reason\":\"\(askReason)\"}\n"
private let resetHardReason =
    "RV · Blocked. Destroys uncommitted changes. Use 'git stash' first."

private func claudeDenyJSON(reason: String) -> String {
    "{\"systemMessage\":\"\(reason)\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"\(reason)\"}}\n"
}

private func adapterSource(rvPath: String) throws -> String {
    try HostAdapterResources.load(for: .claude).rendered(rvPath: rvPath)
}

private func claudeAdapterFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func expectClaudeDeny(_ result: ClaudeWrapperRun, reason: String? = nil) throws {
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("\"permissionDecision\":\"ask\"") == false)
    #expect(result.stdout.contains("\"permissionDecision\": \"ask\"") == false)
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    )
    let hook = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hook["permissionDecision"] as? String == "deny")
    #expect(hook["hookEventName"] as? String == "PreToolUse")
    #expect(Set(hook.keys) == Set(["hookEventName", "permissionDecision", "permissionDecisionReason"]))
    if let reason {
        #expect(hook["permissionDecisionReason"] as? String == reason)
    }
    #expect((json["systemMessage"] as? String)?.isEmpty == false)
}

private struct ClaudeWrapperRun {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var spawnCount: Int
    var lastStdin: String?
}

private enum ClaudeStubRV {
    case missing
    case calls(first: (String, Int32), spend: (String, Int32)?)
}

private func runClaudeWrapper(
    event: [String: Any],
    first: (String, Int32),
    spend: (String, Int32)? = nil,
    confirm: String?
) async throws -> ClaudeWrapperRun {
    try await runClaudeWrapper(
        event: event,
        stub: .calls(first: first, spend: spend),
        confirm: confirm
    )
}

private func runClaudeWrapper(
    event: [String: Any],
    stub: ClaudeStubRV,
    confirm: String?,
    sleepSeconds: Int = 0,
    shimTimeoutSeconds: Int? = nil,
    killSignal: Int32? = nil
) async throws -> ClaudeWrapperRun {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-claude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stubDir = root.appendingPathComponent("stub", isDirectory: true)
    try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)

    let rvPath: String
    switch stub {
    case .missing:
        rvPath = root.appendingPathComponent("missing-rv").path
    case .calls:
        rvPath = root.appendingPathComponent("rv-stub").path
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import pathlib
        import sys

        root = pathlib.Path(os.environ["RV_STUB_DIR"])
        stdin = sys.stdin.read()
        n = int((root / "count").read_text()) if (root / "count").exists() else 0
        n += 1
        (root / "count").write_text(str(n))
        (root / "last-stdin").write_text(stdin)
        if os.environ.get("RV_STUB_SLEEP"):
            import time
            time.sleep(int(os.environ["RV_STUB_SLEEP"]))
        if os.environ.get("RV_STUB_SIGNAL"):
            os.kill(os.getpid(), int(os.environ["RV_STUB_SIGNAL"]))
        is_spend = False
        try:
            parsed = json.loads(stdin)
            is_spend = isinstance(parsed, dict) and parsed.get("hostAsk") == "spend"
        except Exception:
            is_spend = False
        if is_spend and "RV_STUB_SPEND_STDOUT" in os.environ:
            sys.stdout.write(os.environ.get("RV_STUB_SPEND_STDOUT", ""))
            raise SystemExit(int(os.environ.get("RV_STUB_SPEND_EXIT", "0")))
        sys.stdout.write(os.environ.get("RV_STUB_STDOUT", ""))
        raise SystemExit(int(os.environ.get("RV_STUB_EXIT", "0")))
        """
        try script.write(toFile: rvPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rvPath)
    }

    var source = try adapterSource(rvPath: rvPath)
    if let shimTimeoutSeconds {
        let shipped = "RV_HOOK_TIMEOUT_S = 15\n"
        #expect(source.contains(shipped))
        source = source.replacingOccurrences(of: shipped, with: "RV_HOOK_TIMEOUT_S = \(shimTimeoutSeconds)\n")
    }
    let adapter = root.appendingPathComponent("rv-guard.py")
    try source.write(to: adapter, atomically: true, encoding: .utf8)

    let eventData = try JSONSerialization.data(withJSONObject: event)
    let eventText = try #require(String(data: eventData, encoding: .utf8))

    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = root.path
    environment["RV_STUB_DIR"] = stubDir.path
    if sleepSeconds > 0 {
        environment["RV_STUB_SLEEP"] = String(sleepSeconds)
    }
    if let killSignal {
        environment["RV_STUB_SIGNAL"] = String(killSignal)
    }
    if let confirm {
        environment["RV_ASK_CONFIRM"] = confirm
    } else {
        environment.removeValue(forKey: "RV_ASK_CONFIRM")
    }
    switch stub {
    case .calls(let first, let spend):
        environment["RV_STUB_STDOUT"] = first.0
        environment["RV_STUB_EXIT"] = String(first.1)
        if let spend {
            environment["RV_STUB_SPEND_STDOUT"] = spend.0
            environment["RV_STUB_SPEND_EXIT"] = String(spend.1)
        }
    case .missing:
        break
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", adapter.path]
    process.environment = environment
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
    process.waitUntilExit()

    let spawnCount: Int
    if let text = try? String(contentsOf: stubDir.appendingPathComponent("count"), encoding: .utf8) {
        spawnCount = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    } else {
        spawnCount = 0
    }
    let lastStdin = try? String(
        contentsOf: stubDir.appendingPathComponent("last-stdin"),
        encoding: .utf8
    )

    return ClaudeWrapperRun(
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        exitCode: process.terminationStatus,
        spawnCount: spawnCount,
        lastStdin: lastStdin
    )
}
