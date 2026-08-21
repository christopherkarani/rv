import Testing
import RVDomain
import RVIPC
import RVPacks
@testable import RVService

struct ExplainDispatchTests {
    @Test func denyEmitsTTYStageNamesWithZeroElapsed() async throws {
        let runtime = ServiceRuntime(
            catalog: PackCatalog(),
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
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
        let runtime = ServiceRuntime(
            catalog: PackCatalog(),
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
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

    @Test func explainPeeksGrantWithoutSpending() async throws {
        let runtime = ServiceRuntime(
            catalog: PackCatalog(),
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let explained = await runtime.dispatch(
            IPCRequest(method: .explain(ExplainParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .explain(let reply) = explained.result else {
            Issue.record("explain must reply")
            return
        }
        #expect(reply.result.decision == .allow)
        let first = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .evaluate(let allowed) = first.result else {
            Issue.record("expected evaluate reply")
            return
        }
        #expect(allowed.result.decision == .allow)
        let second = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .evaluate(let denied) = second.result else {
            Issue.record("expected second evaluate reply")
            return
        }
        guard case .deny = denied.result.decision else {
            Issue.record("evaluate apply must spend the grant after explain peeked")
            return
        }
    }

    @Test func classifyPeeksGrantWithoutSpending() async throws {
        let runtime = ServiceRuntime(
            catalog: PackCatalog(),
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let classified = await runtime.dispatch(
            IPCRequest(method: .classify(ClassifyParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .classify(let reply) = classified.result else {
            Issue.record("classify must reply")
            return
        }
        #expect(reply.decision == .allow)
        let first = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .evaluate(let allowed) = first.result else {
            Issue.record("expected evaluate reply")
            return
        }
        #expect(allowed.result.decision == .allow)
    }
}
