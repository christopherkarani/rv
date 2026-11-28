import Foundation
import RVDomain
import RVHooks
import Testing

/// Claude PreToolUse wrapper: rv's policy ask never becomes
/// `permissionDecision:ask`; only rv's infrastructure ask does, in prompting
/// modes (ClaudeInfraAskAdapterTests).
struct ClaudeAdapterHookTests {
    /// The baked rv path runs as `rv hook --host claude` for every guarded
    /// tool on PreToolUse, with the host's request passed through unchanged.
    @Test(arguments: ["Bash", "Read", "Edit", "Write"])
    func guardedTool_runsTheBakedRvAsClaudeHook(_ tool: String) async throws {
        let event = tool == "Bash" ? resetHardEvent() : fileToolEvent(tool)
        let result = try await runClaudeWrapper(
            event: event, first: (claudeDenyJSON(reason: resetHardReason), 0), confirm: nil)
        try expectClaudeDeny(result, reason: resetHardReason)
        #expect(result.spawnCount == 1)
        #expect(result.lastArgv == ["hook", "--host", "claude"])
        let forwarded = try #require(result.lastStdin.flatMap { $0.data(using: .utf8) })
        let sent = try #require(JSONSerialization.jsonObject(with: forwarded) as? [String: Any])
        #expect(sent["tool_name"] as? String == tool)
        #expect(sent["hook_event_name"] as? String == "PreToolUse")
    }

    /// A legacy ask never opens a dialog of the adapter's own and is never
    /// confirmed or bypassed through the environment: no `osascript` runs,
    /// rv is asked once (no spend call), and the call blocks.
    @Test func legacyAsk_opensNoDialogAndIgnoresConfirmAndBypassEnvironment() async throws {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-claude-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let marker = bin.appendingPathComponent("osascript-ran")
        let osascript = bin.appendingPathComponent("osascript")
        try "#!/bin/sh\ntouch '\(marker.path)'\necho 'button returned:Allow'\n"
            .write(to: osascript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: osascript.path)
        let path = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")

        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            stub: .calls(first: ("{\"decision\":\"ask\",\"reason\":\"review\"}\n", 0), spend: ("", 0)),
            confirm: "yes",
            environment: ["PATH": path, "RV_BYPASS": "1", "CLAUDE_CODE_SESSION_ATTENDED": "1"]
        )
        try expectClaudeDeny(result, reason: "review")
        #expect(result.spawnCount == 1)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
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
        #expect(result.stdout.contains(jsonStringBody(resetHardReason)))
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

    /// rvd's real deny stays a block in an attended prompting session: only
    /// the C hook's down reasons may become a host prompt.
    @Test(arguments: ["default", "plan", "acceptEdits", "auto"])
    func firstCallProductionRichDeny_staysDenyWhereHostCouldAsk(_ mode: String) async throws {
        var event = resetHardEvent()
        event["permission_mode"] = mode
        let result = try await runClaudeWrapper(
            event: event,
            stub: .calls(first: (try claudeAdapterFixture("deny-git-reset-hard.out"), 0), spend: nil),
            confirm: "yes",
            environment: ["CLAUDE_CODE_SESSION_ATTENDED": "1"]
        )
        try expectClaudeDeny(result, reason: resetHardReason)
        #expect(result.stdout.contains("rv could not check this call") == false)
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
        try expectClaudeDeny(result)
        #expect(result.stdout.contains("rv is not installed at "))
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
        try expectClaudeDeny(result)
        #expect(result.stdout.contains("rv is not installed at "))
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

    // MARK: failure classes not covered by AdapterFailureMessageTests — each blocks.

    /// Every down class the C hook can render as Claude `ask` reaches the
    /// human verbatim; with no permission_mode it blocks.
    @Test(arguments: [cUnreachableReason, cTimeoutReason, cConnectionReason])
    func daemonDownAsk_deniesWithTheCHookReason(_ reason: String) async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (cDownAskJSON(reason: reason), 0),
            confirm: "yes"
        )
        try expectClaudeDeny(result, reason: reason)
        #expect(result.spawnCount == 1)
    }

    /// In an attended Manual-mode session each down class becomes Claude
    /// Code's own prompt: the command first, then the layer that could not
    /// check it and the C hook's text. Through the copies below this also
    /// pins the adapter's table of recognised reasons to hook_fallback.c.
    @Test(arguments: [
        (cUnreachableReason, "rvd is not reachable"),
        (cTimeoutReason, "rvd did not answer in time"),
        (cConnectionReason, "the connection to rvd dropped"),
        (cStoppedReason, "rvd was stopped or crashed"),
    ])
    func daemonDownAsk_inManualModeAsksTheHuman(_ reason: String, layer: String) async throws {
        var event = resetHardEvent()
        event["permission_mode"] = "default"
        let result = try await runClaudeWrapper(
            event: event,
            stub: .calls(first: (cDownAskJSON(reason: reason), 0), spend: nil),
            confirm: "yes",
            environment: ["CLAUDE_CODE_SESSION_ATTENDED": "1"]
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let hook = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(hook["permissionDecision"] as? String == "ask")
        let expected =
            "Bash: git reset --hard\n\nrv could not check this call (\(layer)). An agent can cause "
            + "this by stopping or overloading rvd. Approve only if you expected it. " + reason
        #expect(hook["permissionDecisionReason"] as? String == expected)
        #expect(json["systemMessage"] as? String == expected)
        #expect(result.exitCode == 0)
        #expect(result.spawnCount == 1)
    }

    /// The copies above must be the C hook's real text, not stale duplicates.
    @Test func cDownReasons_matchHookFallbackSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/rv-c/hook_fallback.c")
        let source = try String(contentsOf: url, encoding: .utf8)
        for text in cDownTexts {
            #expect(
                source.contains("static const struct RvFailureText \(text.name) = {\n    \"\(text.rule)\", \"\(text.why)\", \(text.fix)};"),
                "\(text.name) in hook_fallback.c drifted from this test's copy"
            )
        }
        #expect(source.contains("kDoctor[] = \"rv doctor\";"))
        #expect(source.contains("kRestart[] = \"rv service restart\";"))
        #expect(source.contains(#""\xE2\x9C\x95 Stopped   (%s)\nwhy     %s\nwho     ask %s to run  %s""#))
    }

    @Test(arguments: ["Bash", "Read"])
    func daemonDownAskWithoutReason_deniesWithGuidance(_ tool: String) async throws {
        let bare = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}\n"
        let result = try await runClaudeWrapper(
            event: tool == "Bash" ? resetHardEvent() : fileToolEvent(tool),
            first: (bare, 0),
            confirm: "yes"
        )
        try expectClaudeDeny(
            result,
            reason: "rv blocked this action without giving a reason. Run `rv doctor`."
        )
    }

    @Test func killedBySignal_denies() async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            stub: .calls(first: ("", 0), spend: nil),
            confirm: "yes",
            killSignal: 9
        )
        try expectClaudeDeny(result)
        #expect(result.stdout.contains("exited with code -9"), "\(result.stdout)")
        #expect(result.stdout.contains("`rv doctor`"), "\(result.stdout)")
    }

    /// Exit 0 with a reply that is not JSON, not an object, or an unknown shape never allows.
    @Test(arguments: ["not-json\n", "[1,2]\n", "{\"decision\":\"maybe\"}\n"])
    func unusableReplyWithExitZero_denies(_ stdout: String) async throws {
        let result = try await runClaudeWrapper(
            event: resetHardEvent(),
            first: (stdout, 0),
            confirm: "yes"
        )
        try expectClaudeDeny(
            result,
            reason: "rv exited with code 0 without a usable decision. Run `rv doctor`."
        )
    }
}

/// The C hook's down stops (`kUnreachableText` / `kTimeoutText` /
/// `kConnectionText` / `kStoppedText` in `Sources/rv-c/hook_fallback.c`,
/// pinned by `cDownReasons_matchHookFallbackSource`).
private let cDownTexts: [(name: String, rule: String, why: String, fix: String)] = [
    ("kUnreachableText", "rv.hook/unreachable", "rv's daemon is not running", "kDoctor"),
    ("kTimeoutText", "rv.hook/timeout", "rv's daemon did not answer in time", "kDoctor"),
    ("kConnectionText", "rv.hook/connection", "rv lost its daemon before a verdict", "kDoctor"),
    ("kStoppedText", "rv.hook/stopped", "rvd stopped or crashed after it last ran", "kRestart"),
]
private let cUnreachableReason = daemonUnreachableMessage
private let cTimeoutReason = cDownStop("rv.hook/timeout", why: "rv's daemon did not answer in time", fix: "rv doctor")
private let cConnectionReason =
    cDownStop("rv.hook/connection", why: "rv lost its daemon before a verdict", fix: "rv doctor", owner: "Chris")
private let cStoppedReason =
    cDownStop("rv.hook/stopped", why: "rvd stopped or crashed after it last ran", fix: "rv service restart")

/// The C hook's `RV_HOOK_WHEN_DOWN=ask` reply for Claude (`render_ask`).
private func cDownAskJSON(reason: String) -> String {
    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(jsonStringBody(reason))\"},\"systemMessage\":\"\(jsonStringBody(reason))\"}\n"
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
private let resetHardReason = resetHardHostDeny

private func claudeDenyJSON(reason: String) -> String {
    "{\"systemMessage\":\"\(jsonStringBody(reason))\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"\(jsonStringBody(reason))\"}}\n"
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
    var lastArgv: [String]?
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
    killSignal: Int32? = nil,
    environment extra: [String: String] = [:]
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
        (root / "last-argv").write_text(json.dumps(sys.argv[1:]))
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
        try writeExecutableStub(script, toFile: rvPath)
    }

    let source = try pointingOwnerConfig(
        adapterSource(rvPath: rvPath), at: root.appendingPathComponent("owner-config.json"))
    let adapter = root.appendingPathComponent("rv-guard.py")
    try source.write(to: adapter, atomically: true, encoding: .utf8)

    let eventData = try JSONSerialization.data(withJSONObject: event)
    let eventText = try #require(String(data: eventData, encoding: .utf8))

    var environment = adapterTestEnvironment().merging(extra) { _, value in value }
    environment["HOME"] = root.path
    environment["RV_STUB_DIR"] = stubDir.path
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
    let lastArgv = (try? Data(contentsOf: stubDir.appendingPathComponent("last-argv")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }

    return ClaudeWrapperRun(
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        exitCode: process.terminationStatus,
        spawnCount: spawnCount,
        lastStdin: lastStdin,
        lastArgv: lastArgv
    )
}
