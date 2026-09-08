import Foundation
import Testing
import RVDomain
@testable import RVHooks

@Suite("PendingHostAsk hook door")
struct PendingHostAskHookTests {
    @Test func PendingHostAsk_piAskWithSessionRecordsBeforeEncodeAsk() async throws {
        let probe = PendingHostAskProbe()
        let stdin = piAskStdin(session: "sess-pi")
        let wire = await hookWire(
            host: .pi,
            stdin: stdin,
            evaluate: { _, _ in resetHardDeny },
            recordHostAsk: { request, action in
                try await probe.record(request, action)
            }
        )
        let json = try askJSON(wire)
        #expect(json["decision"] as? String == "ask")
        #expect(wire.exitCode == 1)
        let records = await probe.records
        #expect(records.count == 1)
        #expect(records[0].request.session?.rawValue == "sess-pi")
        #expect(records[0].request.host == .pi)
        #expect(records[0].action.supportingCommand?.rawValue == "git reset --hard")
        #expect(await probe.clears.isEmpty)
    }

    @Test func PendingHostAsk_missingSessionStillEncodesAskAndRecords() async throws {
        let probe = PendingHostAskProbe()
        let stdin = piAskStdin(session: nil)
        let wire = await hookWire(
            host: .pi,
            stdin: stdin,
            evaluate: { _, _ in resetHardDeny },
            recordHostAsk: { request, action in
                try await probe.record(request, action)
            }
        )
        let json = try askJSON(wire)
        #expect(json["decision"] as? String == "ask")
        let records = await probe.records
        #expect(records.count == 1)
        #expect(records[0].request.session == nil)
    }

    @Test func PendingHostAsk_createThrowStillEncodesAsk() async throws {
        let probe = PendingHostAskProbe()
        await probe.failRecord(with: .encodeFailed)
        let wire = await hookWire(
            host: .pi,
            stdin: piAskStdin(session: "sess-pi"),
            evaluate: { _, _ in resetHardDeny },
            recordHostAsk: { request, action in
                try await probe.record(request, action)
            }
        )
        let json = try askJSON(wire)
        #expect(json["decision"] as? String == "ask")
        #expect(wire.exitCode == 1)
        #expect(await probe.records.isEmpty)
    }

    @Test func PendingHostAsk_spendClearsAfterSpendAllowAndDeny() async throws {
        let probe = PendingHostAskProbe()
        let allowSpend = await hookWire(
            host: .pi,
            stdin: piSpendStdin(session: "sess-pi"),
            evaluate: { _, _ in resetHardDeny },
            spendHostAsk: { _, _ in
                EvaluationResult(outcome: .plain, matchingView: MatchingView("git reset --hard"))
            },
            clearHostAsk: { request, action in
                try await probe.clear(request, action)
            }
        )
        #expect(allowSpend.stdout.isEmpty)
        #expect(allowSpend.exitCode == 0)
        #expect(await probe.clears.count == 1)

        await probe.reset()
        let denySpend = await hookWire(
            host: .pi,
            stdin: piSpendStdin(session: "sess-pi"),
            evaluate: { _, _ in resetHardDeny },
            spendHostAsk: { _, _ in resetHardDeny },
            clearHostAsk: { request, action in
                try await probe.clear(request, action)
            }
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(denySpend.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(await probe.clears.count == 1)
        #expect(await probe.records.isEmpty)
    }

    @Test func PendingHostAsk_clearThrowDoesNotChangeSpendWire() async throws {
        let probe = PendingHostAskProbe()
        await probe.failClear(with: .lockFailed)
        let wire = await hookWire(
            host: .pi,
            stdin: piSpendStdin(session: "sess-pi"),
            evaluate: { _, _ in resetHardDeny },
            spendHostAsk: { _, _ in
                EvaluationResult(outcome: .plain, matchingView: MatchingView("git reset --hard"))
            },
            clearHostAsk: { request, action in
                try await probe.clear(request, action)
            }
        )
        #expect(wire.stdout.isEmpty)
        #expect(wire.exitCode == 0)
        #expect(await probe.clears.isEmpty)
    }

    @Test(
        arguments: [HookHost.grok, .codex, .cursor, .openclaw]
    )
    func PendingHostAsk_denyOrTTYNeverRecords(_ host: HookHost) async throws {
        let probe = PendingHostAskProbe()
        let wire = await hookWire(
            host: host,
            stdin: denyOrTTYStdin(host),
            evaluate: { _, _ in resetHardDeny },
            recordHostAsk: { request, action in
                try await probe.record(request, action)
            }
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String != "ask")
        #expect(await probe.records.isEmpty)
    }
}

private actor PendingHostAskProbe {
    struct Call: Sendable {
        var request: HookRequest
        var action: ProposedAction
    }

    private(set) var records: [Call] = []
    private(set) var clears: [Call] = []
    private var recordFailure: PendingApprovalError?
    private var clearFailure: PendingApprovalError?

    func record(_ request: HookRequest, _ action: ProposedAction) throws {
        if let recordFailure {
            throw recordFailure
        }
        records.append(Call(request: request, action: action))
    }

    func clear(_ request: HookRequest, _ action: ProposedAction) throws {
        if let clearFailure {
            throw clearFailure
        }
        clears.append(Call(request: request, action: action))
    }

    func failRecord(with error: PendingApprovalError) {
        recordFailure = error
    }

    func failClear(with error: PendingApprovalError) {
        clearFailure = error
    }

    func reset() {
        records = []
        clears = []
        recordFailure = nil
        clearFailure = nil
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
    matchingView: MatchingView("git reset --hard")
)

private func piAskStdin(session: String?) -> String {
    if let session {
        return """
        {"toolName":"bash","cwd":"/tmp/ws","sessionId":"\(session)","input":{"command":"git reset --hard"}}
        """
    }
    return """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"}}
    """
}

private func piSpendStdin(session: String) -> String {
    """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"\(session)","input":{"command":"git reset --hard"},"hostAsk":"spend"}
    """
}

private func denyOrTTYStdin(_ host: HookHost) -> String {
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
    case .openclaw:
        return """
        {"toolName":"exec","cwd":"/tmp/ws","sessionId":"sess-oc","params":{"command":"git reset --hard","workdir":"/tmp/ws"},"toolKind":"exec"}
        """
    case .pi, .opencode, .claude, .hermes:
        return piAskStdin(session: "sess")
    }
}

private func askJSON(_ wire: HookWire) throws -> [String: Any] {
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
    )
    #expect(json["decision"] as? String == "ask")
    #expect(wire.stdout.contains("\"decision\":\"allow\"") == false)
    return json
}
