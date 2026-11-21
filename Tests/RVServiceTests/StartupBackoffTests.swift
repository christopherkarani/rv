#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVService

struct StartupBackoffTests {
    @Test func firstStartAndCleanHistoryStartAtOnceWithPrewarm() {
        for previous in [nil, StartupBackoff.Record.survived] {
            let plan = StartupBackoff.plan(previous: previous)
            #expect(plan.delay == .zero)
            #expect(plan.prewarmJudge)
            #expect(plan.record == StartupBackoff.Record(earlyExits: 0, running: true))
        }
    }

    /// A start that finds `running` knows the previous run died early.
    @Test func earlyExitsGrowTheDelayUpToTheCap() {
        var record: StartupBackoff.Record? = nil
        var delays: [Duration] = []
        var prewarms: [Bool] = []
        for _ in 0..<12 {
            let plan = StartupBackoff.plan(previous: record)
            delays.append(plan.delay)
            prewarms.append(plan.prewarmJudge)
            record = plan.record
        }
        #expect(delays == [0, 0, 5, 10, 20, 40, 80, 160, 300, 300, 300, 300].map { Duration.seconds($0) })
        #expect(prewarms == [true, true] + Array(repeating: false, count: 10))
    }

    @Test func aSurvivedRunResetsTheCount() {
        let looping = StartupBackoff.Record(earlyExits: 9, running: true)
        #expect(StartupBackoff.plan(previous: looping).delay == .seconds(300))
        let plan = StartupBackoff.plan(previous: .survived)
        #expect(plan.delay == .zero)
        #expect(plan.record.earlyExits == 0)
    }

    @Test func aForgedCountIsClampedNeverPastTheCap() {
        for forged in [Int.max, -5, 1_000_000] {
            let plan = StartupBackoff.plan(previous: StartupBackoff.Record(earlyExits: forged, running: true))
            #expect(plan.delay <= StartupBackoff.maxDelay)
            #expect(plan.record.earlyExits <= 65)
        }
    }

    @Test func supervisedOnlyUnderTheRvdJobOrSystemd() {
        #expect(StartupBackoff.isSupervised(environment: ["XPC_SERVICE_NAME": "dev.rv.evaluate"]))
        #expect(StartupBackoff.isSupervised(environment: ["INVOCATION_ID": "abc"]))
        #expect(StartupBackoff.isSupervised(environment: [:]) == false)
        #expect(StartupBackoff.isSupervised(environment: ["XPC_SERVICE_NAME": "0"]) == false)
        #expect(StartupBackoff.isSupervised(environment: ["INVOCATION_ID": ""]) == false)
    }

    @Test func storeRoundTripsAndResets() throws {
        try withStore { store in
            #expect(store.load() == nil)
            store.save(StartupBackoff.Record(earlyExits: 3, running: true))
            #expect(store.load() == StartupBackoff.Record(earlyExits: 3, running: true))
            let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            store.reset()
            #expect(store.load() == nil)
        }
    }

    @Test func storeIgnoresSymlinksOversizeAndGarbage() throws {
        try withStore { store in
            try "not json".write(toFile: store.path, atomically: true, encoding: .utf8)
            #expect(store.load() == nil)
            try String(repeating: " ", count: StartupBackoffStore.maxBytes + 1)
                .write(toFile: store.path, atomically: true, encoding: .utf8)
            #expect(store.load() == nil)
            try FileManager.default.removeItem(atPath: store.path)
            let target = store.path + ".target"
            try #"{"earlyExits":9,"running":true}"#.write(toFile: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: store.path, withDestinationPath: target)
            #expect(store.load() == nil)
        }
    }

    /// A supervised start records itself before any wait, so a run killed
    /// while it waits still counts; the wait uses the injected sleep.
    @Test(arguments: [["XPC_SERVICE_NAME": "dev.rv.evaluate"], ["INVOCATION_ID": "abc"]])
    func supervisedStartRecordsThenWaits(supervisor: [String: String]) throws {
        try withStore { store in
            store.save(StartupBackoff.Record(earlyExits: 1, running: true))
            let environment = supervisor.merging(["HOME": NSTemporaryDirectory()]) { $1 }
            let plan = RVDLifecycle.beginStartup(environment: environment, store: store)
            #expect(store.load() == StartupBackoff.Record(earlyExits: 2, running: true))
            #expect(plan.delay == .seconds(5))
            #expect(plan.prewarmJudge == false)
            #expect(plan.tracked)
            let slept = Mutex<[Duration]>([])
            RVDLifecycle.waitOutBackoff(plan, sleep: { duration in slept.withLock { $0.append(duration) } })
            #expect(slept.withLock { $0 } == [.seconds(5)])
        }
    }

    /// rvd run by hand, by the SDK's ensure_runtime or by rv itself
    /// (DirectRvd) has no supervisor: it never waits, always prewarms, and
    /// neither reads nor writes the record, whatever the record says.
    @Test(arguments: [[:], ["XPC_SERVICE_NAME": "0"], ["INVOCATION_ID": ""]])
    func unsupervisedStartNeverWaitsOrRecords(environment: [String: String]) throws {
        try withStore { store in
            let looping = StartupBackoff.Record(earlyExits: 9, running: true)
            store.save(looping)
            let plan = RVDLifecycle.beginStartup(
                environment: environment.merging(["HOME": NSTemporaryDirectory()]) { $1 }, store: store)
            #expect(plan == StartupBackoff.untracked)
            #expect(store.load() == looping)
            RVDLifecycle.waitOutBackoff(plan, sleep: { _ in Issue.record("slept") })
        }
    }

    @Test func beginStartupWithoutHomeNeverWaits() {
        let plan = RVDLifecycle.beginStartup(environment: ["INVOCATION_ID": "abc"])
        #expect(plan == StartupBackoff.untracked)
    }

    /// A FIFO planted where the record or an old fixed temp name would be
    /// must not hang rvd: load opens non-blocking and refuses it, save
    /// writes a fresh mkstemp file and renames over it.
    @Test func plantedFIFOsNeverHangLoadOrSave() throws {
        try withStore { store in
            #expect(mkfifo(store.path, 0o600) == 0)
            #expect(mkfifo(store.path + ".\(getpid()).tmp", 0o600) == 0)
            let done = DispatchSemaphore(value: 0)
            let loaded = Mutex<StartupBackoff.Record??>(nil)
            // A dedicated thread: under a full parallel run the dispatch pool can
            // be busy for longer than the bound.
            Thread {
                loaded.withLock { $0 = .some(store.load()) }
                store.save(StartupBackoff.Record(earlyExits: 4, running: true))
                done.signal()
            }.start()
            #expect(done.wait(timeout: .now() + 10) == .success, "load or save blocked on a FIFO")
            #expect(loaded.withLock { $0 } == .some(nil))
            #expect(store.load() == StartupBackoff.Record(earlyExits: 4, running: true))
        }
    }

    /// Its own directory beside the log, which RVWiringPaths protects.
    @Test func liveStoreSitsInItsOwnDirectoryBesideTheLog() {
        let store = StartupBackoffStore.live(home: "/h")
        let logs = (RVDLogFile.path(home: "/h") as NSString).deletingLastPathComponent
        #expect(store.path == logs + "/rvd-backoff/rvd-starts.json")
        #expect(RVWiringPaths.matches(store.path, home: "/h"))
        #expect(RVWiringPaths.matches(logs + "/rvd.log", home: "/h") == false)
        #expect(RVWiringPaths.matches(logs + "/rvd-backoff/rvd-starts.json.a1B2c3.tmp", home: "/h"))
    }
}

private func withStore(_ body: (StartupBackoffStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-backoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(StartupBackoffStore(path: root.appendingPathComponent("rvd-starts.json").path))
}
