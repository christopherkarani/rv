import Foundation
import Testing
import RVDomain
@testable import RVHooks

struct HookWirePortsTests {
    @Test func hookWire_portsEvaluateOnly_spendIntentFailCloses() async throws {
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(
            host: .pi,
            stdin: stdin,
            ports: HookWirePorts(evaluate: { _, _ in EvaluationResult(outcome: .plain) })
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(wire.stdout.contains(incompleteEvalSentence))
    }

    @Test func hookWire_portsEvaluateFile_skipsPackEvaluate() async {
        let probe = PortsEvaluateProbe()
        let stdin = """
        {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/.env"}}
        """
        let wire = await hookWire(
            host: .claude,
            stdin: stdin,
            ports: HookWirePorts(
                evaluate: { command, cwd in probe.evaluate(command, cwd) },
                evaluateFile: { action, cwd in probe.evaluateFile(action, cwd) }
            )
        )
        #expect(probe.packCalls == 0)
        #expect(probe.filePaths == ["/tmp/rv-oracle/.env"])
        #expect(wire.stdout.contains("permissionDecision\":\"deny\""))
    }
}

private final class PortsEvaluateProbe: @unchecked Sendable {
    private(set) var packCalls = 0
    private(set) var filePaths: [String] = []

    func evaluate(_: ShellCommand, _: WorkingDirectory?) -> EvaluationResult {
        packCalls += 1
        return EvaluationResult(outcome: .plain)
    }

    func evaluateFile(_ action: FileToolAction, _: WorkingDirectory?) -> EvaluationResult {
        filePaths.append(action.path.rawValue)
        return EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
                    reason: "secret"
                ),
                matched: nil
            )
        )
    }
}
