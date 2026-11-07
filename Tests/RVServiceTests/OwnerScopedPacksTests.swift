import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// Every evaluate door resolves packs from the owner's config, and a caller's
/// list can never drop one the owner enabled: the SDK used to
/// default to day-one and accept `[]`, and the workspace host bridge always
/// sent day-one, so `cloud.aws`-style packs were skipped on those doors.
@Suite("Owner-scoped packs")
struct OwnerScopedPacksTests {
    private let dropTable = ShellCommand(rawValue: "DROP TABLE users")
    private let sqlite = PackID(rawValue: "database.sqlite")

    private func runtimeWithSQLiteEnabled() throws -> (ServiceRuntime, URL) {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])
        let runtime = ServiceRuntime(home: home, allowOnceDirectory: try isolatedAllowOnceDirectory())
        return (runtime, homeURL)
    }

    @Test func evaluateWithEmptyPackListStillAppliesConfiguredPacks() async throws {
        let (runtime, homeURL) = try runtimeWithSQLiteEnabled()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let reply = await runtime.evaluate(EvaluationRequest(command: dropTable, enabledPacks: []))
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("an empty caller pack list must not skip database.sqlite, got \(reply.result.decision)")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
    }

    @Test func evaluateWithDayOneStillAppliesConfiguredPacks() async throws {
        let (runtime, homeURL) = try runtimeWithSQLiteEnabled()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let reply = await runtime.evaluate(.makeDayOne(command: dropTable))
        guard case .deny = reply.result.decision else {
            Issue.record("a day-one request must still see the owner's packs, got \(reply.result.decision)")
            return
        }
    }

    @Test func explainAndClassifySeeConfiguredPacks() async throws {
        let (runtime, homeURL) = try runtimeWithSQLiteEnabled()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let request = EvaluationRequest(command: dropTable, enabledPacks: [])
        let explained = await runtime.dispatch(IPCRequest(method: .explain(ExplainParams(request: request))))
        guard case .explain(let explain) = explained.result, case .deny = explain.result.decision else {
            Issue.record("explain must use configured packs, got \(explained.result)")
            return
        }
        let classified = await runtime.dispatch(IPCRequest(method: .classify(ClassifyParams(request: request))))
        guard case .classify(let classify) = classified.result, case .deny = classify.decision else {
            Issue.record("classify must use configured packs, got \(classified.result)")
            return
        }
    }

    @Test func callerListCannotDropConfiguredPacks() async throws {
        let (runtime, homeURL) = try runtimeWithSQLiteEnabled()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let scoped = await runtime.ownerScoped(
            EvaluationRequest(command: dropTable, enabledPacks: [.coreGit]))
        #expect(scoped.enabledPacks.contains(sqlite))
        for id in dayOnePackIDs {
            #expect(scoped.enabledPacks.contains(id), "\(id.rawValue) dropped by a caller list")
        }
    }
}
