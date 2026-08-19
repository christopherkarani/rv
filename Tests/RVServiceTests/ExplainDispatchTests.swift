import Testing
import RVDomain
import RVIPC
@testable import RVService

struct ExplainDispatchTests {
    @Test func denyEmitsTTYStageNamesWithZeroElapsed() async throws {
        let runtime = try isolatedRuntime()
        let response = await runtime.dispatch(
            IPCRequest(
                method: .explain(
                    ExplainParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git reset --hard"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .explain(let reply) = response.result else {
            Issue.record("explain must reply")
            return
        }
        #expect(reply.stages.map(\.name) == [
            "normalize", "quick-reject", "safe", "destructive",
        ])
        #expect(reply.stages.allSatisfy { $0.elapsedMs == 0 })
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("day-one explain must deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func quickRejectAllowEmitsSkipWalkWithZeroElapsed() async throws {
        let runtime = try isolatedRuntime()
        let response = await runtime.dispatch(
            IPCRequest(
                method: .explain(
                    ExplainParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "ls -la"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .explain(let reply) = response.result else {
            Issue.record("explain must reply")
            return
        }
        #expect(reply.stages.map(\.name) == [
            "normalize", "quick-reject", "default",
        ])
        #expect(reply.stages.allSatisfy { $0.elapsedMs == 0 })
        #expect(reply.result.decision == .allow)
        #expect(reply.result.quickRejected)
    }
}
