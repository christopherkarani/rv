import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
import RVPacks
import RVPolicy
@testable import RVService

/// T3 seam tests: the live compile-set module owns gated-door freshness.
/// Callers request a ready door/world for a wanted set; the 1s throttle,
/// uncovered rebuild, and post-`setPackEnabled` visibility live behind
/// that one interface.
struct LiveCompileSetTests {
    private let sqlite = PackID(rawValue: "database.sqlite")

    @Test func uncoveredWantedRebuildsBeforeDoorIsUsed() async throws {
        let home = try compileSetHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let uptime = UptimeBox(10_000_000_000)
        let set = LiveCompileSet(
            snapshots: try PackRegistry.loadAll(),
            catalog: nil,
            home: home,
            uptimeNanoseconds: { uptime.now }
        )
        #expect(set.compiledPackIDs == dayOnePackIDs)

        // Behind-our-back config edit: no notification reaches the set.
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])

        let world = set.readyWorld(
            wanted: WalkedPackIDs(ids: dayOnePackIDs + [sqlite]),
            store: AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory()),
            grants: EphemeralAllowOnceTable(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        #expect(
            set.compiledPackIDs
                == (dayOnePackIDs + [sqlite]).sorted { $0.rawValue < $1.rawValue }
        )
        let result = await world.apply(
            EvaluationRequest(
                command: ShellCommand(rawValue: "DROP TABLE users"),
                enabledPacks: dayOnePackIDs + [sqlite]
            ),
            cwd: nil
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("ready world must rebuild before evaluate; DROP TABLE must deny")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
    }

    @Test func coveredWantedDoesNotReloadCatalog() throws {
        let home = try compileSetHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let uptime = UptimeBox(10_000_000_000)
        let set = LiveCompileSet(
            snapshots: try PackRegistry.loadAll(),
            catalog: nil,
            home: home,
            uptimeNanoseconds: { uptime.now }
        )
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])

        // Wanted set is fully covered: no catalog reload, no rebuild.
        _ = set.readyDoor(wanted: WalkedPackIDs(ids: dayOnePackIDs))
        #expect(set.compiledPackIDs == dayOnePackIDs)

        // Asking for the uncovered pack is what triggers freshness.
        _ = set.readyDoor(wanted: WalkedPackIDs(ids: dayOnePackIDs + [sqlite]))
        #expect(set.compiledPackIDs.contains(sqlite))
    }

    @Test func uncoveredRetryIsThrottledForOneSecond() throws {
        let home = try compileSetHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let uptime = UptimeBox(10_000_000_000)
        let set = LiveCompileSet(
            snapshots: try PackRegistry.loadAll(),
            catalog: nil,
            home: home,
            uptimeNanoseconds: { uptime.now }
        )
        let missing = PackID(rawValue: "nope.missing")

        // First uncovered ask attempts a rebuild (catalog reload).
        _ = set.readyDoor(wanted: WalkedPackIDs(ids: [missing]))
        #expect(set.compiledPackIDs.contains(missing) == false)

        // Same uncovered ask inside the window: no second reload, so a
        // pack enabled on disk in between stays unseen for now.
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])
        _ = set.readyDoor(wanted: WalkedPackIDs(ids: [missing]))
        #expect(set.compiledPackIDs.contains(sqlite) == false)

        // Past 1s the identical ask retries and the reload lands.
        uptime.now &+= 1_000_000_001
        _ = set.readyDoor(wanted: WalkedPackIDs(ids: [missing]))
        #expect(set.compiledPackIDs.contains(sqlite))
        #expect(set.compiledPackIDs.contains(missing) == false)
    }

    @Test func setPackEnabledIsVisibleImmediatelyWithinThrottleWindow() async throws {
        let home = try compileSetHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let uptime = UptimeBox(10_000_000_000)
        let set = LiveCompileSet(
            snapshots: try PackRegistry.loadAll(),
            catalog: nil,
            home: home,
            uptimeNanoseconds: { uptime.now }
        )

        // Burn the throttle slot on exactly the wanted set used below.
        _ = set.readyDoor(wanted: WalkedPackIDs(ids: dayOnePackIDs + [sqlite]))
        #expect(set.compiledPackIDs.contains(sqlite) == false)

        // The single mutation entry rebuilds at once: the next ready
        // door inside the same throttle window already covers sqlite.
        try set.setPackEnabled(sqlite, enabled: true)
        #expect(set.compiledPackIDs.contains(sqlite))
        let world = set.readyWorld(
            wanted: WalkedPackIDs(ids: dayOnePackIDs + [sqlite]),
            store: AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory()),
            grants: EphemeralAllowOnceTable(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let result = await world.apply(
            EvaluationRequest(
                command: ShellCommand(rawValue: "DROP TABLE users"),
                enabledPacks: dayOnePackIDs + [sqlite]
            ),
            cwd: nil
        )
        guard case .deny = result.decision else {
            Issue.record("post-setPackEnabled evaluate must see the new pack")
            return
        }

        try set.setPackEnabled(sqlite, enabled: false)
        #expect(set.compiledPackIDs == dayOnePackIDs)
    }

    @Test func peekHealsFromBehindTheBackEnable() async throws {
        let home = try compileSetHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let uptime = UptimeBox(10_000_000_000)
        let set = LiveCompileSet(
            snapshots: try PackRegistry.loadAll(),
            catalog: nil,
            home: home,
            uptimeNanoseconds: { uptime.now }
        )
        let peek = set.livePeek(
            store: AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory()),
            grants: EphemeralAllowOnceTable()
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let command = ShellCommand(rawValue: "DROP TABLE users")

        let before = await peek(command, nil, now)
        #expect(before.decision == .allow)

        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])
        let after = await peek(command, nil, now)
        guard case .deny(let deny) = after.decision else {
            Issue.record("peek must not observe a stale door after a disk enable")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
    }

    @Test func explainAndClassifyHealLikeEvaluate() async throws {
        let home = try compileSetHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        #expect(await runtime.compiledPackIDs == dayOnePackIDs)
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])

        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "DROP TABLE users"),
            enabledPacks: dayOnePackIDs + [sqlite]
        )
        let explained = await runtime.dispatch(
            IPCRequest(method: .explain(ExplainParams(request: request)))
        )
        guard case .explain(let explainReply) = explained.result else {
            Issue.record("explain must reply")
            return
        }
        guard case .deny(let explainDeny) = explainReply.result.decision else {
            Issue.record("explain must apply the evaluate coverage rule, not peek stale")
            return
        }
        #expect(explainDeny.ruleID.rawValue == "database.sqlite:drop-table")

        let classified = await runtime.dispatch(
            IPCRequest(method: .classify(ClassifyParams(request: request)))
        )
        guard case .classify(let classifyReply) = classified.result else {
            Issue.record("classify must reply")
            return
        }
        guard case .deny = classifyReply.decision else {
            Issue.record("classify must apply the evaluate coverage rule, not peek stale")
            return
        }
    }
}

private final class UptimeBox: Sendable {
    private let box: Mutex<UInt64>

    init(_ now: UInt64) {
        box = Mutex(now)
    }

    var now: UInt64 {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}

private func compileSetHome() throws -> HomeDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-t3-compileset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: url.path))
}
