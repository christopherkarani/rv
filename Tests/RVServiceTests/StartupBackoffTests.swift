import Foundation
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

    /// The record is written before the wait, so a run killed while it
    /// waits still counts; the wait itself uses the injected sleep.
    @Test func beginStartupRecordsThenWaits() throws {
        try withStore { store in
            store.save(StartupBackoff.Record(earlyExits: 1, running: true))
            let slept = Mutex<[Duration]>([])
            let plan = RVDLifecycle.beginStartup(
                environment: ["HOME": NSTemporaryDirectory()],
                store: store,
                sleep: { duration in
                    #expect(store.load() == StartupBackoff.Record(earlyExits: 2, running: true))
                    slept.withLock { $0.append(duration) }
                }
            )
            #expect(plan.delay == .seconds(5))
            #expect(plan.prewarmJudge == false)
            #expect(slept.withLock { $0 } == [.seconds(5)])
        }
    }

    @Test func beginStartupWithoutHomeNeverWaits() {
        let plan = RVDLifecycle.beginStartup(environment: [:], sleep: { _ in Issue.record("slept") })
        #expect(plan.delay == .zero)
    }

    @Test func liveStoreSitsBesideTheLog() {
        let store = StartupBackoffStore.live(home: "/h")
        #expect((store.path as NSString).deletingLastPathComponent
            == (RVDLogFile.path(home: "/h") as NSString).deletingLastPathComponent)
        #expect(store.path.hasSuffix("/rvd-starts.json"))
    }
}

private func withStore(_ body: (StartupBackoffStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-backoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(StartupBackoffStore(path: root.appendingPathComponent("rvd-starts.json").path))
}
