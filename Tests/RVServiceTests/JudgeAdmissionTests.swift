import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVService

/// A flag an escaping judge body can set (a `Mutex` cannot be captured there).
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// A run time an escaping late-result callback can record.
private final class RunTime: Sendable {
    private let value = Mutex<Duration?>(nil)
    func record(_ ran: Duration) { value.withLock { $0 = ran } }
    var recorded: Duration? { value.withLock { $0 } }
}

private extension JudgeAdmission.Outcome {
    var turnedAway: Bool? {
        if case .turnedAway(let stalled) = self { return stalled }
        return nil
    }

    var answer: T? {
        if case .answered(let value) = self { return value }
        return nil
    }

    var isLate: Bool {
        if case .late = self { return true }
        return false
    }
}

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
        let ran = Flag()
        let third = admission.run(until: nil) { ran.set(); return true }
        #expect(third.turnedAway == false)
        #expect(ran.isSet == false)
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
        let ran = Flag()
        let deadline = begin.advanced(by: .milliseconds(200) + JudgeAdmission.inferenceHeadroom)
        let waited = admission.run(until: deadline) { ran.set(); return true }
        let elapsed = ContinuousClock.now - begin
        #expect(waited.turnedAway == false)
        #expect(ran.isSet == false)
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(2))
    }

    /// A slow prediction holds the model; a hook call behind it waits the
    /// judge budget, not its whole hook deadline.
    @Test func aJudgedCallWaitsAtMostTheBudgetForASlot() {
        let admission = JudgeAdmission(limit: 4)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        occupy(admission, release: release, started: started)
        defer { release.signal() }

        let begin = ContinuousClock.now
        let ran = Flag()
        let waited = admission.run(until: begin.advanced(by: HookDeadline.budget)) { ran.set(); return true }
        let elapsed = ContinuousClock.now - begin
        // Behind a prediction younger than `stallAge`: busy, not stalled.
        #expect(waited.turnedAway == false)
        #expect(ran.isSet == false)
        #expect(elapsed >= JudgeAdmission.waitBudget - .milliseconds(50))
        #expect(elapsed < JudgeAdmission.waitBudget + .seconds(1))
    }

    @Test func theLoadWaitAndTheAdmissionWaitShareOneBudget() {
        let since = ContinuousClock.now
        // A far deadline: the budget ends the wait.
        let budgeted = JudgeAdmission.slotCutoff(until: since.advanced(by: HookDeadline.budget), since: since)
        #expect(budgeted == since.advanced(by: JudgeAdmission.waitBudget))
        // A near deadline: its headroom ends the wait first.
        let near = since.advanced(by: .seconds(2))
        #expect(JudgeAdmission.slotCutoff(until: near, since: since) == near - JudgeAdmission.inferenceHeadroom)
        // No deadline: no bound (the CLI's in-process path).
        #expect(JudgeAdmission.slotCutoff(until: nil, since: since) == nil)
        // A load that took 1 s of the budget leaves 0.5 s for the admission.
        #expect(JudgeAdmission.loadWait(.seconds(5), until: budgeted, now: since.advanced(by: .seconds(1)))
            == JudgeAdmission.waitBudget - .seconds(1))
        #expect(JudgeAdmission.waitBudget == .milliseconds(1500))
    }

    @Test func aDeadlineInsideTheHeadroomNeverRunsTheModel() {
        let admission = JudgeAdmission(limit: 4)
        let ran = Flag()
        let begin = ContinuousClock.now
        let tight = admission.run(
            until: begin.advanced(by: JudgeAdmission.inferenceHeadroom / 2)
        ) { ran.set(); return true }
        #expect(tight.turnedAway == false)
        #expect(ran.isSet == false)
        #expect(ContinuousClock.now - begin < .milliseconds(200))
        #expect(admission.admitted == 0)
    }

    @Test func aSpentDeadlineNeverRunsTheModel() {
        let admission = JudgeAdmission(limit: 4)
        let ran = Flag()
        let late = admission.run(until: ContinuousClock.now.advanced(by: .milliseconds(-1))) {
            ran.set(); return true
        }
        #expect(late.turnedAway == false)
        #expect(ran.isSet == false)
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
        #expect(admission.run(until: nil) { 42 }.answer == 42)
    }

    @Test func aPredictionThatAnswersInTimeIsAnswered() {
        let admission = JudgeAdmission(limit: 4)
        let answered = admission.run(until: ContinuousClock.now.advanced(by: HookDeadline.budget)) { 7 }
        #expect(answered.answer == 7)
        #expect(admission.admitted == 0)
    }

    /// A prediction cannot be cancelled: its caller stops waiting before its
    /// deadline (`late`), the prediction reports itself when it returns, and
    /// a request turned away behind the abandoned prediction is `late` too.
    @Test func aPredictionPastItsCutoffIsLateAndReportsItselfWhenDone() {
        let admission = JudgeAdmission(limit: 4)
        let reported = DispatchSemaphore(value: 0)
        let ranFor = RunTime()
        let begin = ContinuousClock.now
        // Slot cutoff begin+0.4 s; the caller stops waiting at begin+1.15 s.
        let deadline = begin.advanced(by: .milliseconds(1400))
        let first = JudgeRuntime.admitted(
            through: admission, until: deadline, since: begin,
            onLate: { _, ran in
                ranFor.record(ran)
                reported.signal()
            }
        ) {
            Thread.sleep(forTimeInterval: 1.8)
            return .failed
        }
        let waited = ContinuousClock.now - begin
        guard case .late = first else {
            Issue.record("a prediction past its cutoff must answer late, got \(first)")
            return
        }
        #expect(waited >= .milliseconds(1100))
        #expect(waited < .milliseconds(1700))

        // The abandoned prediction still holds the model: the next caller is
        // turned away behind a stalled judge, which counts as late.
        let ran = Flag()
        let behind = JudgeRuntime.admitted(
            through: admission, until: ContinuousClock.now.advanced(by: .milliseconds(1200))
        ) { ran.set(); return .failed }
        guard case .late = behind else {
            Issue.record("a turn-away behind a stalled prediction must answer late, got \(behind)")
            return
        }
        #expect(ran.isSet == false)

        #expect(reported.wait(timeout: .now() + 5) == .success)
        #expect((ranFor.recorded ?? .zero) >= .milliseconds(1750))
        // The model is free again.
        #expect(admission.run(until: ContinuousClock.now.advanced(by: HookDeadline.budget)) { 1 }.answer == 1)
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
        let ran = Flag()
        let refused = JudgeRuntime.admitted(through: full, until: nil) {
            ran.set()
            return .failed
        }
        guard case .busy = refused else {
            Issue.record("a full admission must answer busy, got \(refused)")
            return
        }
        #expect(ran.isSet == false)

        // A deadline inside the headroom is busy too, even when free.
        let free = JudgeAdmission(limit: 1)
        let late = JudgeRuntime.admitted(
            through: free, until: ContinuousClock.now.advanced(by: .milliseconds(10))
        ) { ran.set(); return .failed }
        guard case .busy = late else {
            Issue.record("a spent budget must answer busy, got \(late)")
            return
        }
        #expect(ran.isSet == false)

        // A free admission returns the inference's own result.
        let answered = JudgeRuntime.admitted(through: free, until: nil) { .warming }
        guard case .warming = answered else {
            Issue.record("a free admission must return the inference result, got \(answered)")
            return
        }
    }
}
