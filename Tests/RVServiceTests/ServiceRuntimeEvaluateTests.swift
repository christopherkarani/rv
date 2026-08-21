import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVService

struct ServiceRuntimeEvaluateTests {
    @Test func dispatchEvaluate_emptyEnabledPacksDoesNotRefillDayOne() async throws {
        let runtime = try isolatedRuntime()
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

    @Test func dispatchEvaluate_disabledCatalogPackStillDeniesResetHard() async throws {
        let runtime = try isolatedRuntime()
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

    @Test func dispatchEvaluate_grantHonorsOnceForCwd() async throws {
        let runtime = ServiceRuntime(allowOnceDirectory: try isolatedAllowOnceDirectory())
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let first = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .evaluate(let allowed) = first.result else {
            Issue.record("expected evaluate reply")
            return
        }
        #expect(allowed.result.decision == .allow)
        #expect(allowed.result.policyOverride == .allowOnce)
        #expect(allowed.result.blockingMatch == nil)
        let second = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .evaluate(let denied) = second.result else {
            Issue.record("expected second evaluate reply")
            return
        }
        guard case .deny = denied.result.decision else {
            Issue.record("second evaluate must deny after the grant is spent")
            return
        }
    }

    @Test func classify_honoredAllowIsNotHighBecauseLeftoverMatch() async throws {
        let runtime = ServiceRuntime(allowOnceDirectory: try isolatedAllowOnceDirectory())
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let response = await runtime.dispatch(
            IPCRequest(method: .classify(ClassifyParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .classify(let reply) = response.result else {
            Issue.record("expected classify reply")
            return
        }
        #expect(reply.decision == .allow)
        #expect(reply.risk != .high)
        #expect(reply.risk != .critical)
    }

    @Test func classify_advisoryStashDropMapsMedium() async throws {
        let runtime = try isolatedRuntime()
        let response = await runtime.dispatch(
            IPCRequest(
                method: .classify(
                    ClassifyParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git stash drop"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .classify(let reply) = response.result else {
            Issue.record("expected classify reply")
            return
        }
        #expect(reply.decision == .allow)
        #expect(reply.risk == .medium)
    }
}
