import Foundation
import Testing
import RVDomain
@testable import RVHooks

/// Step 8B: host-free ASK. Every host renders deny-with-guidance and
/// records a pending row; no host emits Ask JSON or native-approves.
@Suite("HostAskHook")
struct HostAskHookTests {
    @Test(arguments: HookHost.allCases)
    func hookWire_unlockablePackDenyAskDenies(_ host: HookHost) async throws {
        let wire = await hookWire(
            host: host,
            stdin: hostAskStdin(host),
            world: hookWorld(evaluate: { _, _ in resetHardPackDeny })
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String != "ask")
        #expect(json["decision"] as? String != "allow")
        #expect(wire.exitCode == host.denyExitCode, "\(host)")
        #expect(wire.stdout.isEmpty == false)
        #expect(wire.stdout.contains(approvalPendingLine), "\(host)")
        #expect(wire.stdout.contains("\"continuation\":\"hostNative\"") == false)
        if host == .codex {
            #expect(json["decision"] as? String == "block")
        } else if host == .cursor {
            #expect(json["permission"] as? String == "deny")
            #expect(json["agent_message"] as? String == cursorAgentAskLine)
        } else if host == .claude {
            let specific = json["hookSpecificOutput"] as? [String: Any]
            #expect(specific?["permissionDecision"] as? String == "deny")
        } else {
            #expect(json["decision"] as? String == "deny")
        }
    }

    @Test(arguments: HookHost.allCases)
    func hookWire_carriedMandatoryHumanAskDenies(_ host: HookHost) async throws {
        let deny = ActionPolicyEngine.Builtin.remoteBranchAsk
        let carried = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        let wire = await hookWire(
            host: host,
            stdin: hostAskStdin(host),
            world: hookWorld(evaluate: { _, _ in carried })
        )
        #expect(wire.exitCode == host.denyExitCode, "\(host)")
        #expect(wire.stdout.isEmpty == false)
        #expect(wire.stdout.contains(approvalPendingLine), "\(host)")
        #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"continuation\":\"hostNative\"") == false)
    }

    @Test func hookWire_piFirstCallPackDenyAskDeniesWhenSpendable() async throws {
        let wire = await hookWire(
            host: .pi,
            stdin: piAskStdin,
            world: hookWorld(evaluate: { _, _ in resetHardPackDeny })
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(wire.exitCode == 1)
        #expect(wire.stdout.isEmpty == false)
        #expect(wire.stdout.contains(approvalPendingLine))
        #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
        #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"continuation\":\"hostNative\"") == false)
    }

    @Test func hookWire_claudeFirstCallPackDenyAskDeniesWhenSpendable() async throws {
        let wire = await hookWire(
            host: .claude,
            stdin: claudeAskStdin,
            world: hookWorld(evaluate: { _, _ in resetHardPackDeny })
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        let specific = json["hookSpecificOutput"] as? [String: Any]
        #expect(specific?["permissionDecision"] as? String == "deny")
        #expect(wire.exitCode == 0)
        #expect(wire.stdout.isEmpty == false)
        #expect((json["systemMessage"] as? String)?.contains(approvalPendingLine) == true)
        #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"permissionDecision\":\"allow\"") == false)
        #expect(wire.stdout.contains("stopReason") == false)
    }

    @Test func hookWire_grokFirstCallPackDenyAskDeniesWhenSpendable() async throws {
        let wire = await hookWire(
            host: .grok,
            stdin: grokAskStdin,
            world: hookWorld(evaluate: { _, _ in resetHardPackDeny })
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(wire.exitCode == 0)
        #expect(wire.stdout.contains(approvalPendingLine))
        let text = json["reason"] as? String ?? ""
        #expect(text.contains("Destroys uncommitted changes"))
        #expect(text.contains("Terminal") == false)
    }

    @Test func hookWire_secretDenyStaysBareDeny() async throws {
        let wire = await hookWire(
            host: .pi,
            stdin: piAskStdin,
            world: hookWorld(evaluate: { _, _ in secretHostDeny })
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(json["rule"] as? String == "core.secrets/env-exfil")
        #expect(wire.stdout.contains(approvalPendingLine) == false)
        #expect(wire.stdout.contains("rv allow-once") == false)
        #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    }

    @Test func hookWire_packAllowBindsAllowWithoutGuidance() async throws {
        let wire = await hookWire(
            host: .pi,
            stdin: piAskStdin,
            world: hookWorld(evaluate: { _, _ in EvaluationResult(outcome: .plain) })
        )
        #expect(wire.stdout.isEmpty)
        #expect(wire.exitCode == 0)
    }

    @Test func hookWire_builtinDenyWithoutBoundStaysBareDeny() async throws {
        let deny = ActionPolicyEngine.Builtin.remoteSharedBranch
        let builtIn = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin main")
        )
        let wire = await hookWire(
            host: .pi,
            stdin: piAskStdin,
            world: hookWorld(evaluate: { _, _ in builtIn })
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(wire.stdout.contains(approvalPendingLine) == false)
        #expect(wire.stdout.contains("rv allow-once") == false)
        #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    }

    @Test func hookWire_firstCallAllowCannotSkipPolicyGate() async throws {
        let deny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes"
        )
        let builtIn = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .allow
        )
        for host in HookHost.allCases {
            let wire = hookWire(
                from: builtIn,
                command: ShellCommand(rawValue: "git reset --hard"),
                using: codec(for: host),
                cwd: wd("/tmp/ws")
            )
            #expect(wire.stdout.isEmpty == false, "\(host)")
            #expect(wire.stdout.contains("\"decision\":\"allow\"") == false, "\(host)")
        }
    }

    @Test(arguments: HookHost.allCases)
    func hookWire_noHostEmitsNativeAsk(_ host: HookHost) async throws {
        // F1 shape: no host value can produce Ask JSON or a native
        // continuation. Ask is deny-with-guidance plus a pending row.
        for result in [resetHardPackDeny, secretHostDeny] {
            let wire = await hookWire(
                host: host,
                stdin: hostAskStdin(host),
                world: hookWorld(evaluate: { _, _ in result })
            )
            #expect(wire.stdout.contains("\"decision\":\"ask\"") == false, "\(host)")
            #expect(wire.stdout.contains("\"permission\":\"ask\"") == false, "\(host)")
            #expect(
                wire.stdout.contains("\"permissionDecision\":\"ask\"") == false,
                "\(host)"
            )
            #expect(wire.stdout.contains("hostNative") == false, "\(host)")
        }
    }
}

private let resetHardPackDeny = EvaluationResult(
    outcome: .deny(
        Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes"
        ),
        matched: nil
    ),
    matchingView: MatchingView("git reset --hard"),
    analysis: .git(.reset(mode: .hard, target: nil))
)

private let secretHostDeny = EvaluationResult(
    outcome: .deny(
        Deny(
            ruleID: RuleID(pack: .coreSecrets, pattern: "env-exfil"),
            reason: "secret material requires an authenticated principal"
        ),
        matched: nil
    ),
    matchingView: MatchingView("cat .env"),
    analysis: .unknown
)

private let piAskStdin = """
{"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"git reset --hard"}}
"""

private let claudeAskStdin = """
{"hook_event_name":"PreToolUse","cwd":"/tmp/ws","session_id":"sess-claude","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}
"""

private let grokAskStdin = """
{"hookEventName":"pre_tool_use","cwd":"/tmp/ws","sessionId":"sess-grok","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
"""

private func hostAskStdin(_ host: HookHost) -> String {
    switch host {
    case .pi:
        return piAskStdin
    case .claude:
        return claudeAskStdin
    case .grok:
        return grokAskStdin
    case .opencode:
        return """
        {"tool":"bash","cwd":"/tmp/ws","sessionId":"sess-oc","args":{"command":"git reset --hard"}}
        """
    case .openclaw:
        return """
        {"toolName":"exec","cwd":"/tmp/ws","sessionId":"sess-oc","params":{"command":"git reset --hard","workdir":"/tmp/ws"},"toolKind":"exec"}
        """
    case .hermes:
        return """
        {"toolName":"terminal","cwd":"/tmp/ws","sessionId":"sess-hermes","args":{"command":"git reset --hard"}}
        """
    case .codex:
        return """
        {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","session_id":"sess-codex","tool_name":"Bash","tool_input":{"command":"git reset --hard","workdir":"/tmp/ws"}}
        """
    case .cursor:
        return """
        {"hook_event_name":"beforeShellExecution","cwd":"/tmp/ws","conversation_id":"sess-cursor","command":"git reset --hard"}
        """
    case .antigravity:
        return """
        {"conversationId":"sess-antigravity","toolCall":{"name":"run_command","args":{"CommandLine":"git reset --hard","Cwd":"/tmp/ws"}},"workspacePaths":["/tmp/ws"]}
        """
    }
}

private func codec(for host: HookHost) -> any HostCodec {
    switch host {
    case .pi: PiHostCodec()
    case .opencode: OpenCodeHostCodec()
    case .claude: ClaudeHostCodec()
    case .openclaw: OpenClawHostCodec()
    case .hermes: HermesHostCodec()
    case .grok: GrokHostCodec()
    case .codex: CodexHostCodec()
    case .cursor: CursorHostCodec()
    case .antigravity: AntigravityHostCodec()
    }
}
