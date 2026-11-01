import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVService

@Suite("Judge work runs off the cooperative pool")
struct JudgeOffloadTests {
    @Test func blockedJudgeWaitsDoNotStarveUnrelatedTasks() async {
        // More blocked judge waits than the cooperative pool has threads: if
        // they ran on the pool, nothing else (Hello, the idle watchdog)
        // could run until the slow load finished. Release and measurement
        // are driven from private Dispatch queues (overcommit) so a starved
        // pool still ends the test: global queues share the pool's
        // constrained thread budget and would starve with it.
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 3
        let release = DispatchSemaphore(value: 0)
        let latency = Mutex<Duration?>(nil)
        DispatchQueue(label: "test.probe").asyncAfter(deadline: .now() + .milliseconds(300)) {
            let spawned = ContinuousClock.now
            Task.detached {
                let ran = ContinuousClock.now
                latency.withLock { $0 = ran - spawned }
            }
        }
        // A starved pool cannot run the probe before the release, so its
        // latency is at least release - probe (4.7 s). The bound sits well
        // below that and well above scheduler noise from the other suites
        // sharing this process on a small CI runner (1.35 s seen on Linux).
        DispatchQueue(label: "test.release").asyncAfter(deadline: .now() + .seconds(5)) {
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
        while latency.withLock({ $0 }) == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let measured = latency.withLock { $0 } ?? .seconds(99)
        #expect(measured < .milliseconds(2500), "unrelated task waited \(measured) behind judge waits")
    }

    @Test func returnsTheBodysValue() async {
        #expect(await JudgeOffload.run { 41 + 1 } == 42)
    }
}
