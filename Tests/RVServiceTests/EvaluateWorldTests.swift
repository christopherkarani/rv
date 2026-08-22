import Foundation
import Testing
import RVDomain
import RVPacks
import RVPolicy
@testable import RVService

struct EvaluateWorldTests {
    @Test func emptyCatalogFallsBackToDayOneCompileSet() {
        #expect(
            EvaluationWorld.enabledIDs(catalog: PackCatalog(), home: "/tmp/rv-world-home")
                == dayOnePackIDs
        )
        let session = EvaluationWorld.makeSession(home: "", snapshots: nil, catalog: PackCatalog())
        #expect(session.corePacksReady)
        #expect(Set(session.compiledPackIDs) == Set(dayOnePackIDs))
    }

    @Test func catalogDisableCannotUncompileDayOneRules() throws {
        var catalog = PackCatalog()
        _ = try catalog.setEnabled(id: .coreGit, enabled: false)
        let ids = EvaluationWorld.enabledIDs(catalog: catalog, home: nil)
        #expect(ids.contains(.coreGit))

        let session = EvaluationWorld.makeSession(home: nil, snapshots: nil, catalog: catalog)
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
        let door = GatedEvaluate(lazySession: {
            builds.increment()
            return EvaluateSession(enabledPacks: dayOnePackIDs)
        })
        #expect(builds.value == 0)

        let denied = await door.run(
            .apply,
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: nil,
            home: "",
            store: store,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        guard case .deny = denied.decision else {
            Issue.record("lazy door must evaluate like an eager one")
            return
        }
        #expect(builds.value == 1)
    }

    @Test func assembleRunsTheWorldOnFirstUse() async throws {
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let door = EvaluationWorld.assemble(home: "", snapshots: nil, catalog: nil)
        let result = await door.run(
            .apply,
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: nil,
            home: "",
            store: store,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("assembled world must deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }
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
