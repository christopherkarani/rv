import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Suite("PendingHostAsk hook door")
struct PendingHostAskHookTests {
    @Test func PendingHostAsk_recordsHostDoorFingerprintAndAnalyzedPushEffects() async throws {
        let probe = PendingHostAskProbe()
        let command = ShellCommand(rawValue: "git push --force origin feature")
        let session = try #require(SessionID(validating: "sess-pi"))
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "push-force-long"),
                    reason: "force-push"
                ),
                matched: nil
            ),
            matchingView: MatchingView(command.rawValue),
            analysis: .git(
                .push(remote: "origin", refspec: "feature", force: .force)
            )
        )
        let wire = await hookWire(
            host: .pi,
            stdin: piAskStdin(session: "sess-pi", command: command.rawValue),
            world: hookWorld(
                evaluate: { _, _ in result },
                recordHostAsk: { request, action in
                    try await probe.record(request, action)
                }
            )
        )
        _ = try askDenyJSON(wire)
        let records = await probe.records
        #expect(records.count == 1)
        let action = records[0].action
        #expect(
            action.fingerprint
                == ActionFingerprint.make(host: .pi, session: session, cwd: cwd, command: command)
        )
        #expect(action.effects.kinds.contains(.remoteSharedBranchMutation))
        #expect(action.resources.branchName == "feature")
        #expect(action.fingerprint.rawValue.contains("shell:git") == false)
    }

    @Test func PendingHostAsk_spendEnvelopeDecodesAsShellAndRecords() async throws {
        // Step 8B: legacy spend envelopes are ordinary shell requests.
        // They ask, deny-with-guidance, and record — never spend.
        let probe = PendingHostAskProbe()
        let wire = await hookWire(
            host: .pi,
            stdin: piSpendStdin(session: "sess-pi", command: "git reset --hard"),
            world: hookWorld(
                evaluate: { _, _ in resetHardDeny },
                recordHostAsk: { request, action in
                    try await probe.record(request, action)
                }
            )
        )
        _ = try askDenyJSON(wire)
        let records = await probe.records
        #expect(records.count == 1)
        #expect(records[0].action.supportingCommand?.rawValue == "git reset --hard")
    }

    @Test func PendingHostAsk_piAskWithSessionRecordsBeforeEncodeAskDeny() async throws {
        let probe = PendingHostAskProbe()
        let stdin = piAskStdin(session: "sess-pi")
        let wire = await hookWire(
            host: .pi,
            stdin: stdin,
            world: hookWorld(
                evaluate: { _, _ in resetHardDeny },
                recordHostAsk: { request, action in
                    try await probe.record(request, action)
                }
            )
        )
        let json = try askDenyJSON(wire)
        #expect(json["rule"] as? String == "core.git/reset-hard")
        #expect(wire.exitCode == 1)
        let records = await probe.records
        #expect(records.count == 1)
        #expect(records[0].request.session?.rawValue == "sess-pi")
        #expect(records[0].request.host == .pi)
        #expect(records[0].action.supportingCommand?.rawValue == "git reset --hard")
        let session = try #require(SessionID(validating: "sess-pi"))
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let command = ShellCommand(rawValue: "git reset --hard")
        #expect(
            records[0].action.fingerprint
                == ActionFingerprint.make(host: .pi, session: session, cwd: cwd, command: command)
        )
        #expect(records[0].action.effects.kinds.contains(.workingTreeDiscard))
        #expect(records[0].action.fingerprint.rawValue.contains("shell:git") == false)
    }

    @Test func PendingHostAsk_missingSessionStillEncodesAskDenyAndCallsRecord() async throws {
        let probe = PendingHostAskProbe()
        let stdin = piAskStdin(session: nil)
        let wire = await hookWire(
            host: .pi,
            stdin: stdin,
            world: hookWorld(
                evaluate: { _, _ in resetHardDeny },
                recordHostAsk: { request, action in
                    try await probe.record(request, action)
                }
            )
        )
        _ = try askDenyJSON(wire)
        // The door invokes the port; HookDoor.recordPending no-ops without
        // a session before touching the store.
        let records = await probe.records
        #expect(records.count == 1)
        #expect(records[0].request.session == nil)
    }

    @Test func PendingHostAsk_createThrowStillEncodesAskDeny() async throws {
        let probe = PendingHostAskProbe()
        await probe.failRecord(with: .encodeFailed)
        let wire = await hookWire(
            host: .pi,
            stdin: piAskStdin(session: "sess-pi"),
            world: hookWorld(
                evaluate: { _, _ in resetHardDeny },
                recordHostAsk: { request, action in
                    try await probe.record(request, action)
                }
            )
        )
        // M-25: no row was recorded, so the wire must not promise RV
        // approval — it renders the unrecorded guidance instead.
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(wire.stdout.contains(approvalUnrecordedLine))
        #expect(wire.stdout.contains(approvalPendingLine) == false)
        #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
        #expect(wire.exitCode == 1)
        #expect(await probe.records.isEmpty)
    }

    @Test func PendingHostAsk_recordThrowUsesUnrecordedGuidanceOnEveryHost() async throws {
        // M-25: the record outcome threads into every host's ask-denial.
        for host in HookHost.allCases {
            let probe = PendingHostAskProbe()
            await probe.failRecord(with: .encodeFailed)
            let wire = await hookWire(
                host: host,
                stdin: askStdin(host),
                world: hookWorld(
                    evaluate: { _, _ in resetHardDeny },
                    recordHostAsk: { request, action in
                        try await probe.record(request, action)
                    }
                )
            )
            #expect(wire.stdout.contains(approvalUnrecordedLine), "\(host)")
            #expect(wire.stdout.contains(approvalPendingLine) == false, "\(host)")
            if host == .cursor {
                #expect(wire.stdout.contains(cursorAgentAskUnrecordedLine), "\(host)")
                #expect(wire.stdout.contains(cursorAgentAskLine) == false, "\(host)")
            }
        }
    }

    @Test func PendingHostAsk_recordedAskKeepsPendingGuidance() async throws {
        // The success path is unchanged: a recorded row still promises RV
        // approval on every host.
        for host in HookHost.allCases {
            let probe = PendingHostAskProbe()
            let wire = await hookWire(
                host: host,
                stdin: askStdin(host),
                world: hookWorld(
                    evaluate: { _, _ in resetHardDeny },
                    recordHostAsk: { request, action in
                        try await probe.record(request, action)
                    }
                )
            )
            #expect(wire.stdout.contains(approvalPendingLine), "\(host)")
            #expect(wire.stdout.contains(approvalUnrecordedLine) == false, "\(host)")
        }
    }

    @Test(
        arguments: HookHost.allCases
    )
    func PendingHostAsk_allHostsRecordAndAskDeny(_ host: HookHost) async throws {
        // Step 8B: every host routes human-required operations to
        // RVOperatorUI. No host denies silently without a pending row.
        let probe = PendingHostAskProbe()
        let wire = await hookWire(
            host: host,
            stdin: askStdin(host),
            world: hookWorld(
                evaluate: { _, _ in resetHardDeny },
                recordHostAsk: { request, action in
                    try await probe.record(request, action)
                }
            )
        )
        #expect(wire.stdout.contains("\"decision\":\"ask\"") == false, "\(host)")
        #expect(wire.stdout.contains("\"permission\":\"ask\"") == false, "\(host)")
        #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false, "\(host)")
        #expect(wire.stdout.contains(approvalPendingLine), "\(host)")
        #expect(wire.stdout.isEmpty == false, "\(host)")
        let records = await probe.records
        #expect(records.count == 1, "\(host)")
    }
}

private actor PendingHostAskProbe {
    struct Call: Sendable {
        var request: HookRequest
        var action: ProposedAction
    }

    private(set) var records: [Call] = []
    private var recordFailure: PendingApprovalError?

    func record(_ request: HookRequest, _ action: ProposedAction) throws {
        if let recordFailure {
            throw recordFailure
        }
        records.append(Call(request: request, action: action))
    }

    func failRecord(with error: PendingApprovalError) {
        recordFailure = error
    }
}

private let resetHardDeny = EvaluationResult(
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

private func piAskStdin(session: String?, command: String = "git reset --hard") -> String {
    if let session {
        return """
        {"toolName":"bash","cwd":"/tmp/ws","sessionId":"\(session)","input":{"command":"\(command)"}}
        """
    }
    return """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"\(command)"}}
    """
}

private func piSpendStdin(session: String, command: String = "git reset --hard") -> String {
    """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"\(session)","input":{"command":"\(command)"},"hostAsk":"spend"}
    """
}

private func askStdin(_ host: HookHost) -> String {
    switch host {
    case .grok:
        return """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","sessionId":"sess-grok","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
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
    case .openclaw:
        return """
        {"toolName":"exec","cwd":"/tmp/ws","sessionId":"sess-oc","params":{"command":"git reset --hard","workdir":"/tmp/ws"},"toolKind":"exec"}
        """
    case .pi:
        return piAskStdin(session: "sess-pi")
    case .opencode:
        return """
        {"tool":"bash","cwd":"/tmp/ws","sessionId":"sess-oc","args":{"command":"git reset --hard"}}
        """
    case .claude:
        return """
        {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","session_id":"sess-claude","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}
        """
    case .hermes:
        return """
        {"toolName":"terminal","cwd":"/tmp/ws","sessionId":"sess-hermes","args":{"command":"git reset --hard"}}
        """
    }
}

private func askDenyJSON(_ wire: HookWire) throws -> [String: Any] {
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "deny")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\"") == false)
    #expect(wire.stdout.contains(approvalPendingLine))
    return json
}
