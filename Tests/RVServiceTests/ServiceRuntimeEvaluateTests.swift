import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

struct ServiceRuntimeEvaluateTests {
    @Test func coveredRequestedPacksStayOnWarmSession() async throws {
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        #expect(await runtime.compiledPackIDs == dayOnePackIDs)

        _ = try PacksFacade.enable(home: home, ids: ["database.sqlite"])
        let reply = await runtime.makeEvaluateReply(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git stash drop"),
                enabledPacks: dayOnePackIDs
            )
        )

        #expect(reply.result.decision == .allow)
        #expect(await runtime.compiledPackIDs == dayOnePackIDs)
    }

    @Test func uncoveredRequestedPacksRebuildWarmSessionCoverage() async throws {
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let sqlite = PackID(rawValue: "database.sqlite")
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])

        let reply = await runtime.makeEvaluateReply(
            EvaluationRequest(
                command: ShellCommand(rawValue: "DROP TABLE users"),
                enabledPacks: dayOnePackIDs + [sqlite]
            )
        )

        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("an uncovered requested pack must rebuild before evaluation")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
        #expect(
            await runtime.compiledPackIDs
                == (dayOnePackIDs + [sqlite]).sorted { $0.rawValue < $1.rawValue }
        )
    }

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
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"))
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let first = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: wd("/tmp/ws"))))
        )
        guard case .evaluate(let allowed) = first.result else {
            Issue.record("expected evaluate reply")
            return
        }
        #expect(allowed.result.decision == .allow)
        let second = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: wd("/tmp/ws"))))
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
}
