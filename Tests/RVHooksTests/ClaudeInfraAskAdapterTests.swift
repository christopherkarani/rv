import Foundation
import RVDomain
import RVHooks
import Testing

/// rv's infrastructure ask (rvd unreachable, slow or dropped, or the whole
/// rv process past the adapter budget) reaches the human as Claude Code's
/// own permission prompt, but only in permission modes where Claude Code
/// puts a hook `ask` to a person. Everything else keeps blocking.
struct ClaudeInfraAskAdapterTests {
    /// Modes that show a hook `ask` to a human: Manual (`default`), `plan`,
    /// `acceptEdits` and `auto` (the classifier does not decide a hook ask).
    static let promptingModes = ["default", "plan", "acceptEdits", "auto"]

    /// `bypassPermissions` skips prompts and `dontAsk` auto-denies them;
    /// a missing, blank, differently-spelled or unknown mode is treated the
    /// same way: no proof a person will be asked.
    static let nonPromptingModes: [String?] = [nil, "bypassPermissions", "dontAsk", "", "Default", "manual", "yolo"]

    static let prefix =
        "rv could not check this call, so Claude Code is asking you. Approve only if you expected it. "

    @Test(arguments: promptingModes)
    func daemonDown_asksTheHumanWithLayerPrefix(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": mode])
        let reason = try expectClaudeAsk(run)
        #expect(reason == Self.prefix + daemonUnreachableMessage, "\(mode): \(reason)")
    }

    @Test(arguments: promptingModes)
    func daemonDown_fileToolAsksToo(_ mode: String) async throws {
        let run = try await runPythonAdapter(
            host: .claude,
            stub: daemonDownWire(.claude),
            eventFields: [
                "permission_mode": mode,
                "tool_name": "Write",
                "tool_input": ["file_path": "/tmp/ws/a.txt", "content": "x"],
            ]
        )
        let reason = try expectClaudeAsk(run)
        #expect(reason == Self.prefix + daemonUnreachableMessage, "\(mode): \(reason)")
    }

    @Test(arguments: nonPromptingModes)
    func daemonDown_blocksWhenNoHumanWouldBeAsked(_ mode: String?) async throws {
        var fields: [String: Any] = [:]
        if let mode { fields["permission_mode"] = mode }
        let run = try await runPythonAdapter(host: .claude, stub: daemonDownWire(.claude), eventFields: fields)
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage, "\(mode ?? "nil"): \(reason)")
    }

    @Test func daemonDown_nonStringModeBlocks() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: daemonDownWire(.claude), eventFields: ["permission_mode": ["default"]])
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason == daemonUnreachableMessage)
    }

    /// The rv process running past the adapter budget is infrastructure.
    @Test func timeout_asksTheHuman() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .sleep(seconds: 5), timeoutSeconds: "0.3",
            eventFields: ["permission_mode": "default"])
        let reason = try expectClaudeAsk(run)
        #expect(reason.hasPrefix(Self.prefix), "\(reason)")
        #expect(reason.contains("rv did not answer within 0.3s"), "\(reason)")
        #expect(reason.contains("`rv doctor`"), "\(reason)")
    }

    @Test func timeout_blocksUnderBypass() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .sleep(seconds: 5), timeoutSeconds: "0.3",
            eventFields: ["permission_mode": "bypassPermissions"])
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.contains("rv did not answer within 0.3s"), "\(reason)")
    }

    @Test func nativeAskWithoutReason_asksWithGuidance() async throws {
        let wire = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}\n"
        let run = try await runPythonAdapter(
            host: .claude, stub: .stdout(wire, exit: 0), eventFields: ["permission_mode": "default"])
        let reason = try expectClaudeAsk(run)
        #expect(reason.hasPrefix(Self.prefix), "\(reason)")
        #expect(reason.contains("`rv doctor`"), "\(reason)")
    }

    /// Install problems, unusable output, rv's deny and rv's policy ask
    /// (Step 8B: approval happens in RVOperatorUI) never become a host
    /// prompt, even where Claude Code would show one.
    @Test(arguments: StillBlocks.allCases)
    func nonInfraFailures_stillBlockWhereHostCouldAsk(_ which: StillBlocks) async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: which.stub, eventFields: ["permission_mode": "default"])
        let reason = try expectFailClosed(host: .claude, run: run)
        #expect(reason.hasPrefix(Self.prefix) == false, "\(which): \(reason)")
    }

    /// No failure path answers allow, whatever the mode.
    @Test(arguments: promptingModes + ["bypassPermissions", "dontAsk"])
    func failures_neverAllow(_ mode: String) async throws {
        let stubs: [AdapterStub] = [daemonDownWire(.claude), .sleep(seconds: 5), .missing, .stdout("", exit: 1)]
        for stub in stubs {
            let run = try await runPythonAdapter(
                host: .claude, stub: stub, timeoutSeconds: "0.3", eventFields: ["permission_mode": mode])
            #expect(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "\(mode)")
            let hook = try wireObject(run.stdout)["hookSpecificOutput"] as? [String: Any]
            let decision = hook?["permissionDecision"] as? String
            #expect(decision == "ask" || decision == "deny", "\(mode): \(decision ?? "nil")")
        }
    }

    /// Observe mode is unchanged: rv's own allow (empty stdout, exit 0)
    /// stays an allow, and nothing is prefixed or prompted.
    @Test func rvAllow_staysEmptyAllow() async throws {
        let run = try await runPythonAdapter(
            host: .claude, stub: .stdout("", exit: 0), eventFields: ["permission_mode": "default"])
        #expect(run.exitCode == 0)
        #expect(run.stdout.isEmpty)
    }

    /// Cursor gives a hook no signal for auto-run, background agents or
    /// `cursor-agent --force`, so its native ask still blocks.
    @Test func cursorNativeAsk_stillBlocks() async throws {
        let run = try await runPythonAdapter(host: .cursor, stub: daemonDownWire(.cursor))
        let reason = try expectFailClosed(host: .cursor, run: run)
        #expect(reason == daemonUnreachableMessage)
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
