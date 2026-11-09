import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVService

/// The judge model answers one request at a time. Without a bound, requests
/// the hook client already gave up on keep queueing behind it and every new
/// request waits longer than the last (seen live: 10 s → 107 s).
@Suite("Judge admission bounds the serialized model queue")
struct JudgeAdmissionTests {
    /// Holds the admission's model slot on a private thread until released.
    private func occupy(
        _ admission: JudgeAdmission, release: DispatchSemaphore, started: DispatchSemaphore
    ) {
        Thread.detachNewThread {
            _ = admission.run(until: nil) {
                started.signal()
                release.wait()
            }
        }
        started.wait()
    }

    @Test func requestsBeyondTheLimitAreRefusedWithoutWaiting() {
        let admission = JudgeAdmission(limit: 2)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        occupy(admission, release: release, started: started)
        // A second request queues for the slot (inside the limit).
        let queued = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = admission.run(until: nil) {}
            queued.signal()
        }
        let entered = ContinuousClock.now.advanced(by: .seconds(10))
        while admission.admitted < 2, ContinuousClock.now < entered { usleep(1_000) }
        guard admission.admitted == 2 else {
            Issue.record("second request never entered the admission")
            release.signal()
            return
        }

        let begin = ContinuousClock.now
        let ran = Mutex(false)
        let third = admission.run(until: nil) { ran.withLock { $0 = true }; return true }
        #expect(third == nil)
        #expect(ran.withLock { $0 } == false)
        #expect(ContinuousClock.now - begin < .seconds(1))

        release.signal()
        queued.wait()
        // The holder leaves the count just after it hands over the model.
        let drained = ContinuousClock.now.advanced(by: .seconds(2))
        while admission.admitted > 0, ContinuousClock.now < drained { usleep(1_000) }
        #expect(admission.admitted == 0)
    }

    @Test func aWaitForTheModelEndsAtTheDeadline() {
        let admission = JudgeAdmission(limit: 4)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        occupy(admission, release: release, started: started)
        defer { release.signal() }

        let begin = ContinuousClock.now
        let ran = Mutex(false)
        let waited = admission.run(until: begin.advanced(by: .milliseconds(200))) {
            ran.withLock { $0 = true }; return true
        }
        let elapsed = ContinuousClock.now - begin
        #expect(waited == nil)
        #expect(ran.withLock { $0 } == false)
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(2))
    }

    @Test func aSpentDeadlineNeverRunsTheModel() {
        let admission = JudgeAdmission(limit: 4)
        let ran = Mutex(false)
        let late = admission.run(until: ContinuousClock.now.advanced(by: .milliseconds(-1))) {
            ran.withLock { $0 = true }; return true
        }
        #expect(late == nil)
        #expect(ran.withLock { $0 } == false)
        #expect(admission.admitted == 0)
    }

    @Test func withoutADeadlineARequestWaitsItsTurn() {
        let admission = JudgeAdmission(limit: 4)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        occupy(admission, release: release, started: started)
        DispatchQueue(label: "test.release").asyncAfter(deadline: .now() + .milliseconds(200)) {
            release.signal()
        }
        #expect(admission.run(until: nil) { 42 } == 42)
    }

    @Test func theOffloadCarriesTheHookDeadlineToTheJudge() async {
        let deadline = HookDeadline()
        let seen = await HookDeadline.$current.withValue(deadline) {
            await JudgeOffload.run { JudgeAdmission.deadline }
        }
        #expect(seen == deadline.expiresAt)
        // Outside a hookEvaluate there is no deadline to carry.
        #expect(await JudgeOffload.run { JudgeAdmission.deadline } == nil)
    }

    @Test func aModelLoadWaitNeverOutlastsTheHookDeadline() {
        let now = ContinuousClock.now
        // No deadline: the configured wait stands (nil still means unbounded).
        #expect(JudgeAdmission.loadWait(.seconds(5), until: nil, now: now) == .seconds(5))
        #expect(JudgeAdmission.loadWait(nil, until: nil, now: now) == nil)
        // A deadline nearer than the wait shortens it; a spent one zeroes it.
        let near = now.advanced(by: .seconds(1))
        #expect(JudgeAdmission.loadWait(.seconds(5), until: near, now: now) == .seconds(1))
        #expect(JudgeAdmission.loadWait(nil, until: near, now: now) == .seconds(1))
        let far = now.advanced(by: .seconds(30))
        #expect(JudgeAdmission.loadWait(.seconds(5), until: far, now: now) == .seconds(5))
        let spent = now.advanced(by: .seconds(-1))
        #expect(JudgeAdmission.loadWait(.seconds(5), until: spent, now: now) == .zero)
    }

    @Test func liveLimitStaysWithinOneHookBudget() {
        // Typical inference is well under a second; a full queue must still
        // clear inside the daemon's 7 s budget instead of piling up.
        #expect(JudgeAdmission.liveLimit >= 2)
        #expect(JudgeAdmission.liveLimit <= 6)
    }
}
