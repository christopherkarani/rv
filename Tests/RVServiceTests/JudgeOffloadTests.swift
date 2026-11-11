import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVService

@Suite("Judge work runs off the cooperative pool")
struct JudgeOffloadTests {
    @Test func blockedJudgeWaitsDoNotStarveUnrelatedTasks() async throws {
        // More blocked judge waits than the cooperative pool has threads: if
        // they ran on the pool, nothing else (Hello, the idle watchdog)
        // could run until the slow load finished. Release and measurement
        // are driven from private Dispatch queues (overcommit) so a starved
        // pool still ends the test: global queues share the pool's
        // constrained thread budget and would starve with it.
        //
        // The invariant, not a latency bound: once every judge wait is
        // blocked, an unrelated task spawned then runs before those waits
        // are released. The release waits for exactly that (or a long cap),
        // so CPU-bound suites sharing this process can delay the probe
        // without failing it, while a starved pool still fails: its probe
        // can only run after the capped release.
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 3
        let release = DispatchSemaphore(value: 0)
        let blocked = Mutex(0)
        let probeRan = Mutex<ContinuousClock.Instant?>(nil)
        let releasedAt = Mutex<ContinuousClock.Instant?>(nil)
        let allBlocked = Mutex(false)
        let cap: Duration = .seconds(60)
        DispatchQueue(label: "test.release").async {
            let started = ContinuousClock.now
            var probeSpawned = false
            while ContinuousClock.now - started < cap {
                if probeSpawned == false, blocked.withLock({ $0 }) == waiters {
                    allBlocked.withLock { $0 = true }
                    probeSpawned = true
                    Task.detached { probeRan.withLock { $0 = ContinuousClock.now } }
                }
                if probeRan.withLock({ $0 }) != nil { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            releasedAt.withLock { $0 = ContinuousClock.now }
            for _ in 0..<waiters { release.signal() }
        }
        let finished = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<waiters {
                group.addTask {
                    await JudgeOffload.run {
                        blocked.withLock { $0 += 1 }
                        release.wait()
                    }
                    return 1
                }
            }
            return await group.reduce(0, +)
        }
        #expect(finished == waiters)
        #expect(allBlocked.withLock { $0 }, "the \(waiters) judge waits never all blocked at once: they starved the pool")
        guard allBlocked.withLock({ $0 }) else { return }
        while probeRan.withLock({ $0 }) == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let ran = try #require(probeRan.withLock { $0 })
        let released = try #require(releasedAt.withLock { $0 })
        #expect(ran < released, "unrelated task only ran \(ran - released) after the judge waits were released")
    }

    @Test func returnsTheBodysValue() async {
        #expect(await JudgeOffload.run { 41 + 1 } == 42)
    }
}
