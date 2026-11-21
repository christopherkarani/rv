import Foundation
import Synchronization
import Testing
@testable import RVJudgePool

@Suite("Judge pool supervisor process")
struct JudgePoolServeTests {
    final class CountingSpawner: WorkerSpawning, Sendable {
        let spawns = Mutex(0)

        struct Refused: Error {}

        func spawn(
            slot: WorkerSlot, compute: WorkerCompute, key: ModelKey, output: @escaping @Sendable (WorkerOutput) -> Void
        ) throws -> any WorkerProcess {
            spawns.withLock { $0 += 1 }
            throw Refused()
        }
    }

    let key = ModelKey(engine: "ft", bundle: "/models/b")

    func executable() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-exe-\(UUID().uuidString)").path
        try Data("bytes".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("a different code hash on disk exits for an upgrade and never spawns the new bytes")
    func codeHashMismatchRefusesSpawn() throws {
        let path = try executable()
        let base = CountingSpawner()
        let upgrades = Mutex(0)
        let guarded = UpgradeGuardedSpawner(
            base: base, executable: path, identity: ExecutableIdentity(path: path),
            codeMatches: { false }, onUpgrade: { upgrades.withLock { $0 += 1 } })
        #expect(throws: WorkerSpawnError.upgraded) {
            _ = try guarded.spawn(slot: .primary, compute: .cpu, key: key) { _ in }
        }
        #expect(upgrades.withLock { $0 } == 1)
        #expect(base.spawns.withLock { $0 } == 0)
    }

    @Test("a replaced executable exits for an upgrade and never spawns it")
    func identityChangeRefusesSpawn() throws {
        let path = try executable()
        let identity = ExecutableIdentity(path: path)
        let staged = path + ".new"
        try Data("other".utf8).write(to: URL(fileURLWithPath: staged))
        #expect(rename(staged, path) == 0)
        let base = CountingSpawner()
        let upgrades = Mutex(0)
        let guarded = UpgradeGuardedSpawner(
            base: base, executable: path, identity: identity, onUpgrade: { upgrades.withLock { $0 += 1 } })
        #expect(throws: WorkerSpawnError.upgraded) {
            _ = try guarded.spawn(slot: .hedge, compute: .accelerated, key: key) { _ in }
        }
        #expect(upgrades.withLock { $0 } == 1)
        #expect(base.spawns.withLock { $0 } == 0)
    }

    @Test("an unchanged executable spawns")
    func unchangedSpawns() throws {
        let path = try executable()
        let base = CountingSpawner()
        let guarded = UpgradeGuardedSpawner(
            base: base, executable: path, identity: ExecutableIdentity(path: path),
            codeMatches: { true }, onUpgrade: { Issue.record("no upgrade") })
        #expect(throws: CountingSpawner.Refused.self) {
            _ = try guarded.spawn(slot: .primary, compute: .cpu, key: key) { _ in }
        }
        #expect(base.spawns.withLock { $0 } == 1)
    }

    @Test("exit is claimed once, however many threads race for it")
    func exitOnce() async {
        let once = ExitOnce()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { once.claim() } }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1)
        #expect(!once.claim())
    }
}
