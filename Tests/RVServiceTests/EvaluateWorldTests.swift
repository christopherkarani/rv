import Foundation
import Testing
import RVDomain
import RVPacks
import RVPolicy
@testable import RVService

struct EvaluateWorldTests {
    @Test func coverageUnionsDayOneOntoEmptyWalk() {
        let coverage = PackCoverage.unioningDayOne(WalkedPackIDs(ids: []))
        #expect(coverage.walked.ids.isEmpty)
        #expect(coverage.compiled.ids == dayOnePackIDs)
    }

    @Test func freshHomeWalksDayOne() throws {
        let home = try isolatedHome()
        #expect(EvaluationWorld.walkedPackIDs(home: home).ids == dayOnePackIDs)
    }

    @Test func nilHomeWalksDayOne() {
        #expect(EvaluationWorld.walkedPackIDs(home: nil).ids == dayOnePackIDs)
    }

    @Test func enabledExtrasWalkBeyondDayOne() throws {
        let home = try isolatedHome()
        _ = try PacksFacade.enable(home: home, ids: ["database"])
        let walked = EvaluationWorld.walkedPackIDs(home: home)
        #expect(walked.ids.contains(PackID(rawValue: "database.sqlite")))
        #expect(walked.ids.count == dayOnePackIDs.count + 8)
    }

    @Test func disabledDayOneStaysOffWalkAndOnCompile() throws {
        let home = try isolatedHome()
        _ = try PacksFacade.disable(home: home, ids: ["core.git"])
        let walked = EvaluationWorld.walkedPackIDs(home: home)
        #expect(walked.ids.contains(PackID(rawValue: "core.git")) == false)
        let coverage = PackCoverage.unioningDayOne(walked)
        #expect(coverage.walked.ids.contains(PackID(rawValue: "core.git")) == false)
        #expect(coverage.compiled.ids.contains(PackID(rawValue: "core.git")))
    }

    @Test func emptyCatalogFallsBackToDayOneCompileSet() throws {
        let empty = PackCatalog(records: [])
        let coverage = EvaluationWorld.coverage(
            catalog: empty,
            home: try isolatedHome()
        )
        #expect(coverage.compiled.ids == dayOnePackIDs)
        let session = EvaluationWorld.makeSession(
            coverage: coverage,
            snapshots: try PackRegistry.loadDayOne()
        )
        #expect(session.corePacksReady)
        #expect(Set(session.compiledPackIDs) == Set(dayOnePackIDs))
    }

    @Test func catalogDisableCannotUncompileDayOneRules() throws {
        var catalog = PackCatalog()
        _ = try catalog.setEnabled(id: .coreGit, enabled: false)
        let coverage = EvaluationWorld.coverage(catalog: catalog, home: try isolatedHome())
        #expect(coverage.walked.ids.contains(.coreGit) == false)
        #expect(coverage.compiled.ids.contains(.coreGit))

        let session = EvaluationWorld.makeSession(
            coverage: coverage,
            snapshots: try PackRegistry.loadDayOne()
        )
        #expect(session.corePacksReady)
        let result = session.evaluate(resetHardRequest())
        guard case .deny(let deny) = result.decision else {
            Issue.record("catalog disable must not uncompile day-one required rules")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")

        let walkedResult = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: coverage.walked.ids
            )
        )
        #expect(walkedResult.decision == .allow)
    }

    @Test func nilCatalogNilHomeIsDayOneWalkAndCompile() {
        let coverage = EvaluationWorld.coverage(catalog: nil, home: nil)
        #expect(coverage.walked.ids == dayOnePackIDs)
        #expect(coverage.compiled.ids == dayOnePackIDs)
    }

    @Test func lazyDoorDefersCompilationUntilFirstUse() async throws {
        let builds = BuildCounter()
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let home = try isolatedHome()
        let snapshots = try PackRegistry.loadDayOne()
        let door = GatedEvaluate(lazySession: {
            builds.increment()
            return EvaluateSession(snapshots: snapshots, enabledPacks: dayOnePackIDs)
        })
        #expect(builds.value == 0)

        let denied = await applyResetHard(door, home: home, store: store)
        guard case .deny = denied.decision else {
            Issue.record("lazy door must evaluate like an eager one")
            return
        }
        #expect(builds.value == 1)
    }

    @Test func lazyDoorReusesSessionOnSecondRun() async throws {
        let builds = BuildCounter()
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let home = try isolatedHome()
        let snapshots = try PackRegistry.loadDayOne()
        let door = GatedEvaluate(lazySession: {
            builds.increment()
            return EvaluateSession(snapshots: snapshots, enabledPacks: dayOnePackIDs)
        })

        let first = await applyResetHard(door, home: home, store: store)
        let second = await applyResetHard(door, home: home, store: store)
        guard case .deny = first.decision, case .deny = second.decision else {
            Issue.record("both runs must deny git reset --hard")
            return
        }
        #expect(builds.value == 1)
    }

    @Test func lazyDoorReusesSessionAfterCorePacksReady() async throws {
        let builds = BuildCounter()
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let home = try isolatedHome()
        let snapshots = try PackRegistry.loadDayOne()
        let door = GatedEvaluate(lazySession: {
            builds.increment()
            return EvaluateSession(snapshots: snapshots, enabledPacks: dayOnePackIDs)
        })

        #expect(door.corePacksReady)
        #expect(builds.value == 1)

        let denied = await applyResetHard(door, home: home, store: store)
        guard case .deny = denied.decision else {
            Issue.record("corePacksReady must not rebuild before evaluate")
            return
        }
        #expect(builds.value == 1)
    }

    @Test func assembleRunsTheWorldOnFirstUse() async throws {
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let home = try isolatedHome()
        let snapshots = try PackRegistry.loadDayOne()
        let door = EvaluationWorld.assemble(home: home, snapshots: snapshots, catalog: nil)
        let result = await applyResetHard(door, home: home, store: store)
        guard case .deny(let deny) = result.decision else {
            Issue.record("assembled world must deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }
}

private func isolatedHome() throws -> HomeDirectory {
    try #require(HomeDirectory(validating: isolatedHomeDirectory().path))
}

private func applyResetHard(
    _ door: GatedEvaluate,
    home: HomeDirectory,
    store: AllowOnceStore
) async -> EvaluationResult {
    await door.run(
        .apply,
        command: ShellCommand(rawValue: "git reset --hard"),
        cwd: nil,
        home: home,
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

private func resetHardRequest() -> EvaluationRequest {
    EvaluationRequest(
        command: ShellCommand(rawValue: "git reset --hard"),
        enabledPacks: dayOnePackIDs
    )
}

private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
