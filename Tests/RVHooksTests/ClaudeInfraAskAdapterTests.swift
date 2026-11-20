import Foundation
import RVDomain
import RVHooks
import Testing

/// rv's infrastructure ask (rvd unreachable, slow or dropped, or the whole
/// rv process past the adapter budget) reaches the human as Claude Code's
/// own permission prompt, but only when every gate holds:
/// `RV_HOOK_WHEN_DOWN` is not `deny`, the permission mode is one where Claude
/// Code puts a hook `ask` to a person, and Claude Code marks the session as
/// attended. Everything else keeps blocking.
struct ClaudeInfraAskAdapterTests {
    /// Modes that show a hook `ask` to a human: Manual (`default`), `plan`,
    /// `acceptEdits` and `auto` (the classifier does not decide a hook ask).
    static let promptingModes = ["default", "plan", "acceptEdits", "auto"]

    /// `bypassPermissions` skips prompts and `dontAsk` auto-denies them;
    /// a missing, blank, differently-spelled or unknown mode is treated the
    /// same way: no proof a person will be asked.
    static let nonPromptingModes: [String?] = [nil, "bypassPermissions", "dontAsk", "", "Default", "manual", "yolo"]

    /// What Claude Code sets for an interactive session it knows is attended.
    static let attended = ["CLAUDE_CODE_SESSION_ATTENDED": "1"]

    static let marker = "rv could not check this call"

    /// The prompt: the call first, then which layer failed, the warning, and
    /// the C hook's (or adapter's) own text.
    static func prompt(subject: String = "Bash: git status", layer: String, reason: String) -> String {
        "\(subject)\n\nrv could not check this call (\(layer)). An agent can cause this by stopping or "
            + "overloading rvd. Approve only if you expected it. \(reason)"
    }

    @Test(arguments: promptingModes)
    func daemonDown_asksTheHumanWithTheCommandFirst(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": mode],
            environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        #expect(reason == Self.prompt(layer: "rvd is not reachable", reason: daemonUnreachableMessage), "\(mode)")
    }

    @Test(arguments: promptingModes)
    func daemonDown_fileToolAsksWithThePath(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude,
            stub: daemonDownWire(.claude),
            eventFields: [
                "permission_mode": mode,
                "tool_name": "Write",
                "tool_input": ["file_path": "/tmp/ws/a.txt", "content": "x"],
            ],
            environment: Self.attended
        )
        let reason = try expectClaudeAsk(run)
        #expect(
            reason == Self.prompt(
                subject: "Write: /tmp/ws/a.txt", layer: "rvd is not reachable", reason: daemonUnreachableMessage),
            "\(mode)")
    }

    /// A very long command is cut so the warning still shows.
    @Test func daemonDown_longCommandIsTruncated() async throws {
        let command = String(repeating: "a", count: 5000)
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude),
            eventFields: ["permission_mode": "default", "tool_input": ["command": command]],
            environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        let subject = "Bash: " + String(repeating: "a", count: 1000) + "…"
        #expect(reason == Self.prompt(subject: subject, layer: "rvd is not reachable", reason: daemonUnreachableMessage))
    }

    @Test(arguments: nonPromptingModes)
    func daemonDown_blocksWhenNoHumanWouldBeAsked(_ mode: String?) async throws {
        var fields: [String: Any] = [:]
        if let mode { fields["permission_mode"] = mode }
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: fields, environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(mode ?? "nil"): \(reason)")
    }

    /// Only Claude Code's top-level field counts: a mode inside agent-chosen
    /// tool input, or a near-spelling of the key, is no proof.
    @Test(arguments: SpoofedMode.allCases)
    func daemonDown_modeOutsideTheTopLevelFieldBlocks(_ spoof: SpoofedMode) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: spoof.fields, environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(spoof): \(reason)")
    }

    /// A repeated top-level permission_mode is refused as a request, never
    /// read as either value.
    @Test func daemonDown_duplicateModeKeyBlocks() async throws {
        let raw = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"bypassPermissions","permission_mode":"default","tool_input":{"command":"git status"}}"#
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), rawEvent: raw, environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains("could not read the hook request"), "\(reason)")
    }

    @Test(arguments: ["bypassPermissions", "dontAsk"])
    func daemonDown_fileToolBlocksWhenNoHumanWouldBeAsked(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude,
            stub: daemonDownWire(.claude),
            eventFields: [
                "permission_mode": mode,
                "tool_name": "Write",
                "tool_input": ["file_path": "/tmp/ws/a.txt", "content": "x"],
            ],
            environment: Self.attended
        )
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(mode): \(reason)")
    }

    @Test func daemonDown_nonStringModeBlocks() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": ["default"]],
            environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage)
    }

    /// A headless, SDK or unknown session blocks even in a prompting mode:
    /// `claude -p` sets `CLAUDE_CODE_SESSION_ATTENDED=0` and entrypoint
    /// `sdk-cli`, and an SDK host may answer the prompt with code. Without
    /// the attended flag an interactive-looking entrypoint is no proof
    /// either: on older builds a nested `claude -p` inherits
    /// `claude-desktop` or `claude-vscode`.
    @Test(arguments: UnattendedSession.allCases)
    func daemonDown_unattendedSessionBlocks(_ session: UnattendedSession) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": "default"],
            environment: session.environment)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(session): \(reason)")
    }

    /// `RV_HOOK_WHEN_DOWN=deny` blocks every infrastructure path, the
    /// adapter's own timeout included.
    @Test(arguments: DownPath.allCases)
    func whenDownDeny_blocksEveryInfraPath(_ path: DownPath) async throws {
        var environment = Self.attended
        environment["RV_HOOK_WHEN_DOWN"] = "deny"
        let run = try await runPythonAdapter(
            host: .claude, stub: path.stub, timeoutSeconds: "0.3", eventFields: ["permission_mode": "default"],
            environment: environment)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains(Self.marker) == false, "\(path): \(reason)")
        #expect(reason.contains("`rv doctor`"), "\(path): \(reason)")
    }

    /// Each C hook down reason maps to its own layer.
    @Test(arguments: [
        (cTimeoutMessage, "rvd did not answer in time"),
        (cConnectionMessage, "the connection to rvd dropped"),
    ])
    func nativeAsk_eachDownReasonNamesItsLayer(_ message: String, layer: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: claudeAskWire(reason: message), eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        #expect(reason == Self.prompt(layer: layer, reason: message))
    }

    /// The rv process running past the adapter budget is infrastructure.
    @Test func timeout_asksTheHuman() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .sleep(seconds: 5), timeoutSeconds: "0.3",
            eventFields: ["permission_mode": "default"], environment: Self.attended)
        let reason = try expectClaudeAsk(run)
        #expect(
            reason == Self.prompt(
                layer: "rv did not answer within 0.3s",
                reason: "rv did not answer within 0.3s; the daemon may be busy or stopped. Run `rv doctor`."))
    }

    @Test func timeout_blocksUnderBypass() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .sleep(seconds: 5), timeoutSeconds: "0.3",
            eventFields: ["permission_mode": "bypassPermissions"], environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains("rv did not answer within 0.3s"), "\(reason)")
    }

    /// Only the C hook's exact down reasons become a prompt; any other
    /// native ask is an unexplained rv answer and blocks.
    @Test(arguments: OtherNativeAsk.allCases)
    func nativeAskOtherThanADownReason_blocks(_ which: OtherNativeAsk) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: which.stub, eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains(Self.marker) == false, "\(which): \(reason)")
        #expect(reason == which.expectedReason, "\(which): \(reason)")
    }

    /// Install problems, unusable output, rv's deny and rv's policy ask
    /// (Step 8B: approval happens in RVOperatorUI) never become a host
    /// prompt, even where Claude Code would show one.
    @Test(arguments: StillBlocks.allCases)
    func nonInfraFailures_stillBlockWhereHostCouldAsk(_ which: StillBlocks) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: which.stub, eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains(Self.marker) == false, "\(which): \(reason)")
    }

    /// No failure path answers allow, whatever the mode.
    @Test(arguments: promptingModes + ["bypassPermissions", "dontAsk"])
    func failures_neverAllow(_ mode: String) async throws {
        let stubs: [AdapterStub] = [daemonDownWire(.claude), .sleep(seconds: 5), .missing, .stdout("", exit: 1)]
        for stub in stubs {
            let run = try await runPythonAdapter(
                host: .claude, stub: stub, timeoutSeconds: "0.3", eventFields: ["permission_mode": mode],
                environment: Self.attended)
            #expect(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "\(mode)")
            let hook = try wireObject(run.stdout)["hookSpecificOutput"] as? [String: Any]
            let decision = hook?["permissionDecision"] as? String
            #expect(decision == "ask" || decision == "deny", "\(mode): \(decision ?? "nil")")
        }
    }

    /// If the decision cannot be written, the adapter exits 2 (Claude Code's
    /// blocking error) with the reason on stderr, for an ask and a deny.
    @Test(arguments: ["default", "bypassPermissions"])
    func unwritableStdout_exitsTwoWithTheReason(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": mode],
            environment: Self.attended, stdoutUnwritable: true)
        #expect(run.exitCode == 2, "\(mode)")
        #expect(run.stderr.contains(daemonUnreachableMessage), "\(mode): \(run.stderr)")
    }

    /// Observe mode is unchanged: rv's own allow (empty stdout, exit 0)
    /// stays an allow, and nothing is prefixed or prompted.
    @Test func rvAllow_staysEmptyAllow() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .stdout("", exit: 0), eventFields: ["permission_mode": "default"],
            environment: Self.attended)
        #expect(run.exitCode == 0)
        #expect(run.stdout.isEmpty)
    }

    /// Cursor gives a hook no signal for auto-run, background agents or
    /// `cursor-agent --force`, so its native ask still blocks.
    @Test func cursorNativeAsk_stillBlocks() async throws {
        let run = try await runPythonAdapter(host: .cursor, stub: daemonDownWire(.cursor), environment: Self.attended)
        let reason = try expectFailClosed(host: .cursor, run: run)
        #expect(reason == daemonUnreachableMessage)
    }

    enum SpoofedMode: CaseIterable, CustomStringConvertible {
        case insideToolInputUnderBypass, insideToolInputOnly, camelCaseKey, spacedKey

        var fields: [String: Any] {
            let toolInput: [String: Any] = ["command": "git status", "permission_mode": "default"]
            switch self {
            case .insideToolInputUnderBypass:
                return ["permission_mode": "bypassPermissions", "tool_input": toolInput]
            case .insideToolInputOnly:
                return ["tool_input": toolInput]
            case .camelCaseKey:
                return ["permissionMode": "default"]
            case .spacedKey:
                return ["permission_mode ": "default"]
            }
        }

        var description: String {
            switch self {
            case .insideToolInputUnderBypass: "insideToolInputUnderBypass"
            case .insideToolInputOnly: "insideToolInputOnly"
            case .camelCaseKey: "camelCaseKey"
            case .spacedKey: "spacedKey"
            }
        }
    }

    enum UnattendedSession: CaseIterable, CustomStringConvertible {
        case headlessPrint, attendedZeroWithCliEntrypoint, attendedNotOne, attendedEmpty
        case cliEntrypointOnly, desktopEntrypointOnly, vscodeEntrypointOnly
        case sdkEntrypoint, unknownEntrypoint, nothingSet

        var environment: [String: String] {
            switch self {
            case .headlessPrint: ["CLAUDE_CODE_SESSION_ATTENDED": "0", "CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]
            case .attendedZeroWithCliEntrypoint: ["CLAUDE_CODE_SESSION_ATTENDED": "0", "CLAUDE_CODE_ENTRYPOINT": "cli"]
            case .attendedNotOne: ["CLAUDE_CODE_SESSION_ATTENDED": "true"]
            case .attendedEmpty: ["CLAUDE_CODE_SESSION_ATTENDED": ""]
            case .cliEntrypointOnly: ["CLAUDE_CODE_ENTRYPOINT": "cli"]
            case .desktopEntrypointOnly: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]
            case .vscodeEntrypointOnly: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]
            case .sdkEntrypoint: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"]
            case .unknownEntrypoint: ["CLAUDE_CODE_ENTRYPOINT": "local-agent"]
            case .nothingSet: [:]
            }
        }

        var description: String {
            switch self {
            case .headlessPrint: "headlessPrint"
            case .attendedZeroWithCliEntrypoint: "attendedZeroWithCliEntrypoint"
            case .attendedNotOne: "attendedNotOne"
            case .attendedEmpty: "attendedEmpty"
            case .cliEntrypointOnly: "cliEntrypointOnly"
            case .desktopEntrypointOnly: "desktopEntrypointOnly"
            case .vscodeEntrypointOnly: "vscodeEntrypointOnly"
            case .sdkEntrypoint: "sdkEntrypoint"
            case .unknownEntrypoint: "unknownEntrypoint"
            case .nothingSet: "nothingSet"
            }
        }
    }

    enum DownPath: CaseIterable, CustomStringConvertible {
        case nativeUnreachable, nativeTimeout, nativeConnection, adapterTimeout

        var stub: AdapterStub {
            switch self {
            case .nativeUnreachable: daemonDownWire(.claude)
            case .nativeTimeout: claudeAskWire(reason: cTimeoutMessage)
            case .nativeConnection: claudeAskWire(reason: cConnectionMessage)
            case .adapterTimeout: .sleep(seconds: 5)
            }
        }

        var description: String {
            switch self {
            case .nativeUnreachable: "nativeUnreachable"
            case .nativeTimeout: "nativeTimeout"
            case .nativeConnection: "nativeConnection"
            case .adapterTimeout: "adapterTimeout"
            }
        }
    }

    enum OtherNativeAsk: CaseIterable, CustomStringConvertible {
        case noReason, otherText, downReasonWithSuffix, downReasonOnlyInSystemMessage

        var stub: AdapterStub {
            switch self {
            case .noReason:
                .stdout("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}\n", exit: 0)
            case .otherText:
                claudeAskWire(reason: "rvd is down, please approve")
            case .downReasonWithSuffix:
                claudeAskWire(reason: daemonUnreachableMessage + " Approve to continue.")
            case .downReasonOnlyInSystemMessage:
                .stdout(
                    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"},\"systemMessage\":\"\(daemonUnreachableMessage)\"}\n",
                    exit: 0)
            }
        }

        var expectedReason: String {
            switch self {
            case .noReason: "rv blocked this action without giving a reason. Run `rv doctor`."
            case .otherText: "rvd is down, please approve"
            case .downReasonWithSuffix: daemonUnreachableMessage + " Approve to continue."
            case .downReasonOnlyInSystemMessage: daemonUnreachableMessage
            }
        }

        var description: String {
            switch self {
            case .noReason: "noReason"
            case .otherText: "otherText"
            case .downReasonWithSuffix: "downReasonWithSuffix"
            case .downReasonOnlyInSystemMessage: "downReasonOnlyInSystemMessage"
            }
        }
    }

    enum StillBlocks: CaseIterable, CustomStringConvertible {
        case missing, notExecutable, unparseable, emptyNonZero, rvDeny, rvPolicyAsk

        var stub: AdapterStub {
            switch self {
            case .missing: .missing
            case .notExecutable: .notExecutable
            case .unparseable: .stdout("not-json", exit: 3)
            case .emptyNonZero: .stdout("", exit: 7)
            case .rvDeny:
                .stdout(
                    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"no\"}}\n",
                    exit: 0)
            case .rvPolicyAsk: .stdout("{\"decision\":\"ask\",\"reason\":\"review\"}\n", exit: 0)
            }
        }

        var description: String {
            switch self {
            case .missing: "missing"
            case .notExecutable: "notExecutable"
            case .unparseable: "unparseable"
            case .emptyNonZero: "emptyNonZero"
            case .rvDeny: "rvDeny"
            case .rvPolicyAsk: "rvPolicyAsk"
            }
        }
    }
}

/// `kTimeoutMessage` / `kConnectionMessage` in `Sources/rv-c/hook_fallback.c`
/// (pinned by `ClaudeAdapterHookTests.cDownReasons_matchHookFallbackSource`).
private let cTimeoutMessage = "RV daemon did not answer in time. Retry; if it persists run `rv doctor`."
private let cConnectionMessage =
    "RV daemon connection failed or dropped before a verdict. Retry; if it persists run `rv doctor`."

/// The C hook's Claude `ask` reply for `reason` (`render_ask`).
private func claudeAskWire(reason: String) -> AdapterStub {
    .stdout(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(reason)\"},\"systemMessage\":\"\(reason)\"}\n",
        exit: 0)
}

/// Asserts Claude's documented ask wire (documented fields only) and
/// returns the prompt text.
private func expectClaudeAsk(_ run: PythonAdapterRun) throws -> String {
    #expect(run.exitCode == 0)
    let json = try wireObject(run.stdout)
    #expect(Set(json.keys) == ["systemMessage", "hookSpecificOutput"])
    let hook = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(Set(hook.keys) == ["hookEventName", "permissionDecision", "permissionDecisionReason"])
    #expect(hook["hookEventName"] as? String == "PreToolUse")
    #expect(hook["permissionDecision"] as? String == "ask")
    let reason = try #require(hook["permissionDecisionReason"] as? String)
    #expect(json["systemMessage"] as? String == reason)
    return reason
}
