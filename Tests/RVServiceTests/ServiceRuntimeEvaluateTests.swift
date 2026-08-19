import Testing
import RVDomain
import RVIPC
@testable import RVService

struct ServiceRuntimeEvaluateTests {
    @Test func dispatchEvaluate_emptyEnabledPacksDoesNotRefillDayOne() async {
        let runtime = ServiceRuntime()
        let response = await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git reset --hard"),
                            enabledPacks: []
                        )
                    )
                )
            )
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("expected evaluate reply")
            return
        }
        if case .deny = reply.result.decision {
            Issue.record("empty enabledPacks means none enabled, not day-one refill")
        }
        #expect(reply.result.decision == .allow)
    }

    @Test func dispatchEvaluate_disabledCatalogPackStillDeniesResetHard() async {
        let runtime = ServiceRuntime()
        let disable = await runtime.dispatch(
            IPCRequest(
                method: .setPackEnabled(SetPackEnabledParams(id: .coreGit, enabled: false))
            )
        )
        guard case .setPackEnabled = disable.result else {
            Issue.record("expected setPackEnabled reply")
            return
        }
        let response = await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git reset --hard"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("expected evaluate reply")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("catalog disable must not change the evaluate set")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }
}
