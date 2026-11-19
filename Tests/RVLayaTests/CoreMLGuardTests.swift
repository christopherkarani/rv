import Foundation
import Synchronization
import Testing
@testable import RVLaya

private let day: TimeInterval = 24 * 3600
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Core ML crash policy")
struct CoreMLCrashPolicyTests {
    @Test("a clean previous run keeps the GPU")
    func cleanRunKeepsGPU() {
        let next = CoreMLCrashPolicy.recover(CoreMLCrashState(), previousRunCrashed: false, now: t0)
        #expect(next.state == CoreMLCrashState())
        #expect(next.units == .cpuAndGPU)
    }

    @Test("one crash is recorded but keeps the GPU")
    func oneCrashKeepsGPU() {
        let next = CoreMLCrashPolicy.recover(CoreMLCrashState(), previousRunCrashed: true, now: t0)
        #expect(next.state.crashes == [t0])
        #expect(next.units == .cpuAndGPU)
    }

    @Test("a second crash inside 24 h switches to CPU only for the cooldown")
    func secondCrashTrips() {
        let prior = CoreMLCrashState(crashes: [t0])
        let now = t0.addingTimeInterval(day - 60)
        let next = CoreMLCrashPolicy.recover(prior, previousRunCrashed: true, now: now)
        #expect(next.units == .cpuOnly)
        #expect(next.state.cpuOnlyUntil == now.addingTimeInterval(CoreMLCrashPolicy.cooldown))
        #expect(next.state.crashes.count == 2)
    }

    @Test("crashes older than the window are forgotten")
    func oldCrashesPruned() {
        let prior = CoreMLCrashState(crashes: [t0])
        let now = t0.addingTimeInterval(day + 1)
        let next = CoreMLCrashPolicy.recover(prior, previousRunCrashed: true, now: now)
        #expect(next.state.crashes == [now])
        #expect(next.units == .cpuAndGPU)
    }

    @Test("CPU only holds through the cooldown without new crashes, then the GPU returns")
    func cooldownHoldsThenExpires() {
        let tripped = CoreMLCrashState(crashes: [t0, t0], cpuOnlyUntil: t0.addingTimeInterval(CoreMLCrashPolicy.cooldown))
        let during = CoreMLCrashPolicy.recover(tripped, previousRunCrashed: false, now: t0.addingTimeInterval(3 * day))
        #expect(during.units == .cpuOnly)
        #expect(during.state.crashes.isEmpty)
        let after = CoreMLCrashPolicy.recover(
            during.state, previousRunCrashed: false,
            now: t0.addingTimeInterval(CoreMLCrashPolicy.cooldown + 1))
        #expect(after.units == .cpuAndGPU)
        #expect(after.state == CoreMLCrashState())
    }

    @Test("future-dated crash records (clock moved back) do not pin anything")
    func futureCrashesDropped() {
        let prior = CoreMLCrashState(crashes: [t0.addingTimeInterval(10 * day)])
        let next = CoreMLCrashPolicy.recover(prior, previousRunCrashed: false, now: t0)
        #expect(next.state.crashes.isEmpty)
        #expect(next.units == .cpuAndGPU)
    }
}

/// In-memory crash store: the marker byte and state survive "process
/// restarts" (new guards over the same store).
final class FakeCrashStore: CoreMLCrashStore, @unchecked Sendable {
    let box = Mutex<(marker: Bool, state: CoreMLCrashState, writes: [Bool])>((false, CoreMLCrashState(), []))

    var marker: Bool { box.withLock { $0.marker } }
    var state: CoreMLCrashState { box.withLock { $0.state } }
    var writes: [Bool] { box.withLock { $0.writes } }

    func previousRunCrashed() -> Bool { box.withLock { $0.marker } }
    func setInFlight(_ inFlight: Bool) {
        box.withLock {
            $0.marker = inFlight
            $0.writes.append(inFlight)
        }
    }
    func loadState() -> CoreMLCrashState { box.withLock { $0.state } }
    func saveState(_ state: CoreMLCrashState) { box.withLock { $0.state = state } }
}

struct FakeDisk: DiskSpaceProbe {
    let free: Int64?
    func availableBytes(at url: URL) -> Int64? { free }
}

final class Recorder: @unchecked Sendable {
    let lines = Mutex<[String]>([])
    let purges = Mutex(0)
    func log(_ line: String) { lines.withLock { $0.append(line) } }
    func purge() { purges.withLock { $0 += 1 } }
    var all: [String] { lines.withLock { $0 } }
    var purgeCount: Int { purges.withLock { $0 } }
}

private func makeGuard(
    _ store: FakeCrashStore, free: Int64? = 100 << 30, recorder: Recorder = Recorder(), now: Date = t0
) -> CoreMLGuard {
    CoreMLGuard(
        store: store, disk: FakeDisk(free: free), cacheVolume: URL(fileURLWithPath: "/tmp"),
        purgeCoreMLCache: { recorder.purge() }, log: { recorder.log($0) }, now: { now })
}

@Suite("Core ML guard")
struct CoreMLGuardTests {
    @Test("run marks Core ML in flight around the body and clears it after")
    func marksAroundBody() throws {
        let store = FakeCrashStore()
        let guardian = makeGuard(store)
        let seen = try guardian.run { store.marker }
        #expect(seen == true)
        #expect(store.marker == false)
    }

    @Test("nested and overlapping runs write the marker only at the edges")
    func nestedRunsWriteEdgesOnly() throws {
        let store = FakeCrashStore()
        let guardian = makeGuard(store)
        try guardian.run { try guardian.run { () } }
        // Startup clear, then one set and one clear for the outer run.
        #expect(store.writes == [false, true, false])
    }

    @Test("a throwing body still clears the marker")
    func throwingBodyClears() {
        struct Boom: Error {}
        let store = FakeCrashStore()
        let guardian = makeGuard(store)
        #expect(throws: Boom.self) { try guardian.run { throw Boom() } }
        #expect(store.marker == false)
    }

    @Test("a leftover marker counts one crash, purges the Core ML cache, and clears")
    func leftoverMarkerRecordsCrash() {
        let store = FakeCrashStore()
        store.setInFlight(true)  // the previous rvd died inside Core ML
        let recorder = Recorder()
        let guardian = makeGuard(store, recorder: recorder)
        #expect(guardian.computeUnits == .cpuAndGPU)
        #expect(store.state.crashes == [t0])
        #expect(store.marker == false)
        #expect(recorder.purgeCount == 1)
        #expect(recorder.all.contains { $0.contains("died inside Core ML") })
    }

    @Test("two crashes in a day switch the next process to CPU only and log it")
    func twoCrashesSwitchToCPU() throws {
        let store = FakeCrashStore()
        // First process crashes mid-prediction.
        let first = makeGuard(store)
        _ = first.computeUnits
        store.setInFlight(true)
        // Second process: one crash so far, still GPU, then it crashes too.
        let second = makeGuard(store, now: t0.addingTimeInterval(600))
        #expect(second.computeUnits == .cpuAndGPU)
        store.setInFlight(true)
        // Third process: CPU only.
        let recorder = Recorder()
        let third = makeGuard(store, recorder: recorder, now: t0.addingTimeInterval(1200))
        #expect(third.computeUnits == .cpuOnly)
        #expect(third.status.units == .cpuOnly)
        #expect(third.status.cpuOnlyUntil != nil)
        #expect(recorder.all.contains { $0.contains("CPU only") })
    }

    @Test("recovery runs before the first marker write, so a run cannot hide the leftover")
    func recoveryPrecedesFirstRun() throws {
        let store = FakeCrashStore()
        store.setInFlight(true)
        let guardian = makeGuard(store)
        try guardian.run { () }
        #expect(store.state.crashes == [t0])
    }

    @Test("low disk refuses before the body runs and never sets the marker")
    func lowDiskRefuses() {
        let store = FakeCrashStore()
        let guardian = makeGuard(store, free: CoreMLGuard.minimumFreeBytes - 1)
        var ran = false
        #expect(throws: CoreMLDiskSpaceError.self) { try guardian.run { ran = true } }
        #expect(ran == false)
        #expect(store.writes.contains(true) == false)
        #expect(guardian.status.diskLow == true)
    }

    @Test("the disk refusal says why and what to do")
    func diskReason() {
        let error = CoreMLDiskSpaceError(availableBytes: 1 << 30, requiredBytes: 2 << 30)
        #expect(error.reason.contains("disk nearly full"))
        #expect(error.reason.contains("judge disabled until space is freed"))
    }

    @Test("unknown free space does not block the judge")
    func unknownFreeSpaceProceeds() throws {
        let guardian = makeGuard(FakeCrashStore(), free: nil)
        #expect(try guardian.run { 7 } == 7)
    }

    @Test("the store opens on first Core ML use, once, not when the guard is made")
    func storeOpensLazily() throws {
        let opened = Mutex(0)
        let store = FakeCrashStore()
        let guardian = CoreMLGuard(
            makeStore: { opened.withLock { $0 += 1 }; return store },
            disk: FakeDisk(free: 100 << 30), cacheVolume: nil,
            purgeCoreMLCache: {}, log: { _ in }, now: { t0 })
        #expect(opened.withLock { $0 } == 0)
        try guardian.run { () }
        _ = guardian.computeUnits
        #expect(opened.withLock { $0 } == 1)
        #expect(store.writes == [false, true, false])
    }

    @Test("an untracked guard writes no marker and loads with the GPU")
    func untrackedGuard() throws {
        let guardian = CoreMLGuard(
            store: nil, disk: FakeDisk(free: 100 << 30), cacheVolume: nil,
            purgeCoreMLCache: {}, log: { _ in }, now: { t0 })
        #expect(guardian.computeUnits == .cpuAndGPU)
        #expect(try guardian.run { 1 } == 1)
    }
}

private func scratch(_ name: String = #function) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-coreml-guard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

@Suite("Core ML crash file store")
struct FileCoreMLCrashStoreTests {
    @Test("the marker survives into the next store (the next process)")
    func markerSurvives() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(FileCoreMLCrashStore(directory: dir))
        #expect(first.previousRunCrashed() == false)
        first.setInFlight(true)
        let second = try #require(FileCoreMLCrashStore(directory: dir))
        #expect(second.previousRunCrashed() == true)
        second.setInFlight(false)
        let third = try #require(FileCoreMLCrashStore(directory: dir))
        #expect(third.previousRunCrashed() == false)
    }

    @Test("state round-trips and a corrupt file reads as empty")
    func stateRoundTrip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(FileCoreMLCrashStore(directory: dir))
        let state = CoreMLCrashState(crashes: [t0], cpuOnlyUntil: t0.addingTimeInterval(day))
        store.saveState(state)
        #expect(try #require(FileCoreMLCrashStore(directory: dir)).loadState() == state)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(FileCoreMLCrashStore.stateName))
        #expect(store.loadState() == CoreMLCrashState())
    }

    @Test("a symlinked store directory is refused")
    func symlinkedDirectoryRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(FileCoreMLCrashStore(directory: link) == nil)
    }

    @Test("a symlinked marker is refused")
    func symlinkedMarkerRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("elsewhere")
        try Data("x".utf8).write(to: target)
        let store = dir.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: store.appendingPathComponent(FileCoreMLCrashStore.markerName), withDestinationURL: target)
        #expect(FileCoreMLCrashStore(directory: store) == nil)
        #expect(try Data(contentsOf: target) == Data("x".utf8))
    }
}

@Suite("Core ML e5rt cache purge")
struct CoreMLCachePurgeTests {
    @Test("purges rvd's e5rt bundle cache")
    func purgesOwnCache() throws {
        let caches = try scratch()
        defer { try? FileManager.default.removeItem(at: caches) }
        let e5rt = caches.appendingPathComponent("rvd/com.apple.e5rt.e5bundlecache/26A428/x.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: e5rt, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: e5rt.appendingPathComponent("resources.bin"))
        #expect(CoreMLCachePurge.purge(cachesRoot: caches, processName: "rvd") == true)
        #expect(!FileManager.default.fileExists(
            atPath: caches.appendingPathComponent("rvd/com.apple.e5rt.e5bundlecache").path))
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("rvd").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: caches.appendingPathComponent("rvd").path)
        #expect(leftovers.isEmpty)
    }

    @Test("never follows a symlinked cache directory")
    func refusesSymlink() throws {
        let caches = try scratch()
        defer { try? FileManager.default.removeItem(at: caches) }
        let precious = caches.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("file"))
        let rvd = caches.appendingPathComponent("rvd", isDirectory: true)
        try FileManager.default.createDirectory(at: rvd, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: rvd.appendingPathComponent("com.apple.e5rt.e5bundlecache"), withDestinationURL: precious)
        #expect(CoreMLCachePurge.purge(cachesRoot: caches, processName: "rvd") == false)
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("file").path))
    }

    @Test("never follows a symlinked process cache directory")
    func refusesSymlinkedParent() throws {
        let caches = try scratch()
        defer { try? FileManager.default.removeItem(at: caches) }
        let precious = caches.appendingPathComponent("precious/com.apple.e5rt.e5bundlecache", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(
            at: caches.appendingPathComponent("rvd"),
            withDestinationURL: caches.appendingPathComponent("precious"))
        #expect(CoreMLCachePurge.purge(cachesRoot: caches, processName: "rvd") == false)
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("file").path))
    }

    @Test("only rvd's own cache is ever purged")
    func otherProcessesUntouched() throws {
        let caches = try scratch()
        defer { try? FileManager.default.removeItem(at: caches) }
        let other = caches.appendingPathComponent("Xcode/com.apple.e5rt.e5bundlecache", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(CoreMLCachePurge.purge(cachesRoot: caches, processName: "Xcode") == false)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("a missing cache is already purged")
    func missingIsFine() throws {
        let caches = try scratch()
        defer { try? FileManager.default.removeItem(at: caches) }
        #expect(CoreMLCachePurge.purge(cachesRoot: caches, processName: "rvd") == true)
    }
}
