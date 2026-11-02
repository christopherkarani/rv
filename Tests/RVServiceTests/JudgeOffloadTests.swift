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
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 3
        let release = DispatchSemaphore(value: 0)
        // The invariant, not a latency bound: an unrelated task spawned while
        // every judge wait is blocked runs before those waits are released.
        // A starved pool could only run it after the release. Other suites in
        // this process can delay it (seconds on a small CI runner), so the
        // 5 s gap leaves room for noise without hiding real starvation.
        let probeRan = Mutex<ContinuousClock.Instant?>(nil)
        let releasedAt = Mutex<ContinuousClock.Instant?>(nil)
        DispatchQueue(label: "test.probe").asyncAfter(deadline: .now() + .milliseconds(300)) {
            Task.detached {
                probeRan.withLock { $0 = ContinuousClock.now }
            }
        }
        DispatchQueue(label: "test.release").asyncAfter(deadline: .now() + .milliseconds(5300)) {
            releasedAt.withLock { $0 = ContinuousClock.now }
            for _ in 0..<waiters { release.signal() }
        }
        let finished = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<waiters {
                group.addTask {
                    await JudgeOffload.run { release.wait() }
                    return 1
                }
            }
            return await group.reduce(0, +)
        }
        #expect(finished == waiters)
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
