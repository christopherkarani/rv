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
        if started.wait(timeout: .now() + 5) == .timedOut {
            Issue.record("the occupying request never reached the model")
            release.signal()
        }
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
        let deadline = begin.advanced(by: .milliseconds(200) + JudgeAdmission.inferenceHeadroom)
        let waited = admission.run(until: deadline) {
            ran.withLock { $0 = true }; return true
        }
        let elapsed = ContinuousClock.now - begin
        #expect(waited == nil)
        #expect(ran.withLock { $0 } == false)
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(2))
    }

    @Test func aDeadlineInsideTheHeadroomNeverRunsTheModel() {
        let admission = JudgeAdmission(limit: 4)
        let ran = Mutex(false)
        let begin = ContinuousClock.now
        let tight = admission.run(
            until: begin.advanced(by: JudgeAdmission.inferenceHeadroom / 2)
        ) { ran.withLock { $0 = true }; return true }
        #expect(tight == nil)
        #expect(ran.withLock { $0 } == false)
        #expect(ContinuousClock.now - begin < .milliseconds(200))
        #expect(admission.admitted == 0)
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

    @Test func aFullLiveQueueClearsInsideOneHookBudget() {
        // Nominal inference per request; the last admitted one must still
        // finish before the daemon's budget runs out.
        let nominalInference: Duration = .milliseconds(500)
        #expect(
            nominalInference * JudgeAdmission.liveLimit + JudgeAdmission.inferenceHeadroom
                <= HookDeadline.budget)
    }

    @Test func liveInferenceGoesThroughTheAdmission() {
        // A full admission turns inference away without running it.
        let full = JudgeAdmission(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        occupy(full, release: release, started: started)
        defer { release.signal() }
        let ran = Mutex(false)
        let refused = JudgeRuntime.admitted(through: full, until: nil) {
            ran.withLock { $0 = true }
            return .failed
        }
        guard case .busy = refused else {
            Issue.record("a full admission must answer busy, got \(refused)")
            return
        }
        #expect(ran.withLock { $0 } == false)

        // A deadline inside the headroom is busy too, even when free.
        let free = JudgeAdmission(limit: 1)
        let late = JudgeRuntime.admitted(
            through: free, until: ContinuousClock.now.advanced(by: .milliseconds(10))
        ) { ran.withLock { $0 = true }; return .failed }
        guard case .busy = late else {
            Issue.record("a spent budget must answer busy, got \(late)")
            return
        }
        #expect(ran.withLock { $0 } == false)

        // A free admission returns the inference's own result.
        let answered = JudgeRuntime.admitted(through: free, until: nil) { .warming }
        guard case .warming = answered else {
            Issue.record("a free admission must return the inference result, got \(answered)")
            return
        }
    }
}
