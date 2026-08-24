import Foundation
import Testing
import RVDomain
import RVPacks
import RVPolicy
@testable import RVService

struct EvaluateWorldTests {
    @Test func emptyCatalogFallsBackToDayOneCompileSet() throws {
        let empty = PackCatalog(records: [])
        #expect(
            EvaluationWorld.enabledIDs(
                catalog: empty,
                home: try isolatedHome()
            )
                == CompileSet(ids: dayOnePackIDs)
        )
        let session = EvaluationWorld.makeSession(
            home: try isolatedHome(),
            snapshots: try PackRegistry.loadDayOne(),
            catalog: empty
        )
        #expect(session.corePacksReady)
        #expect(Set(session.compiledPackIDs) == Set(dayOnePackIDs))
    }

    @Test func catalogDisableCannotUncompileDayOneRules() throws {
        var catalog = PackCatalog()
        _ = try catalog.setEnabled(id: .coreGit, enabled: false)
        let ids = EvaluationWorld.enabledIDs(catalog: catalog, home: try isolatedHome())
        #expect(ids.ids.contains(.coreGit))

        let session = EvaluationWorld.makeSession(
            home: try isolatedHome(),
            snapshots: try PackRegistry.loadDayOne(),
            catalog: catalog
        )
        #expect(session.corePacksReady)
        let result = session.evaluate(resetHardRequest())
        guard case .deny(let deny) = result.decision else {
            Issue.record("catalog disable must not uncompile day-one required rules")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
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

    @Test func nilCatalogAndNilHomeIsDayOneCompileSet() {
        #expect(
            EvaluationWorld.enabledIDs(catalog: nil, home: nil)
                == CompileSet(ids: dayOnePackIDs)
        )
    }

    @Test func compileSetUnionsDayOneWhileWalkSetHonorsDisable() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        _ = try PacksFacade.disable(home: home, ids: ["core.git"])
        let walk = EnabledPacks.resolve(home: home)
        #expect(walk.ids.contains(.coreGit) == false)

        let catalog = try PacksFacade.makeCatalog(home: home)
        let compile = EvaluationWorld.enabledIDs(catalog: catalog, home: home)
        #expect(compile.ids.contains(.coreGit))
        #expect(compile != CompileSet(ids: walk.ids))
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
        now: Date(timeIntervalSince1970: 1_700_000_000)
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
