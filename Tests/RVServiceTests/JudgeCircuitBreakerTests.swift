import Foundation
import Synchronization
import Testing
@testable import RVService

/// A clock tests advance by hand.
private final class ManualClock: Sendable {
    private let instant: Mutex<ContinuousClock.Instant>
    init(_ start: ContinuousClock.Instant = .now) { instant = Mutex(start) }
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ by: Duration) { instant.withLock { $0 = $0.advanced(by: by) } }
}

/// On Nov 19 one judge outage lasted 92 minutes: Core ML predictions took
/// 4-145 s and cannot be cancelled, so every judged call waited behind the
/// stuck one and came back busy. The breaker stops callers queueing on a
/// judge that keeps failing them.
@Suite("Judge circuit breaker")
struct JudgeCircuitBreakerTests {
    private func trip(_ breaker: inout JudgeCircuitBreaker, at now: ContinuousClock.Instant) {
        for _ in 0..<JudgeCircuitBreaker.tripCount {
            #expect(breaker.admit(now: now) == .proceed(trial: false))
            breaker.record(.failure, trial: false, now: now)
        }
    }

    @Test func closedAdmitsAndOpensOnTheThirdFailureInsideTheWindow() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        breaker.record(.failure, trial: false, now: t0)
        breaker.record(.failure, trial: false, now: t0.advanced(by: .seconds(10)))
        #expect(breaker.admit(now: t0.advanced(by: .seconds(11))) == .proceed(trial: false))
        breaker.record(.failure, trial: false, now: t0.advanced(by: .seconds(20)))
        #expect(breaker.state == .open(until: t0.advanced(by: .seconds(80))))
        #expect(breaker.admit(now: t0.advanced(by: .seconds(21))) == .skip(retryIn: .seconds(59)))
    }

    @Test func failuresOlderThanTheWindowDoNotCount() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        breaker.record(.failure, trial: false, now: t0)
        breaker.record(.failure, trial: false, now: t0.advanced(by: .seconds(20)))
        // 31 s after the first: only two failures are inside the window.
        breaker.record(.failure, trial: false, now: t0.advanced(by: .seconds(31)))
        #expect(breaker.admit(now: t0.advanced(by: .seconds(31))) == .proceed(trial: false))
        breaker.record(.failure, trial: false, now: t0.advanced(by: .seconds(32)))
        #expect(breaker.admit(now: t0.advanced(by: .seconds(32))) == .skip(retryIn: .seconds(60)))
    }

    @Test func successesAndNeutralOutcomesNeverOpenIt() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        for i in 0..<10 {
            breaker.record(i.isMultiple(of: 2) ? .success : .neutral, trial: false, now: t0)
        }
        #expect(breaker.state == .closed(failures: []))
    }

    @Test func afterTheCooldownOneTrialRunsAndEveryoneElseStillSkips() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        trip(&breaker, at: t0)
        let reopen = t0.advanced(by: JudgeCircuitBreaker.cooldown)
        #expect(breaker.admit(now: reopen) == .proceed(trial: true))
        #expect(breaker.state == .halfOpen(trialInFlight: true))
        guard case .skip = breaker.admit(now: reopen) else {
            Issue.record("a second call during the trial must skip the judge")
            return
        }
    }

    @Test func aSuccessfulTrialClosesIt() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        trip(&breaker, at: t0)
        let reopen = t0.advanced(by: JudgeCircuitBreaker.cooldown)
        _ = breaker.admit(now: reopen)
        breaker.record(.success, trial: true, now: reopen)
        #expect(breaker.state == .closed(failures: []))
        #expect(breaker.admit(now: reopen) == .proceed(trial: false))
    }

    @Test func aFailedTrialReopensForAnotherCooldown() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        trip(&breaker, at: t0)
        let reopen = t0.advanced(by: JudgeCircuitBreaker.cooldown)
        _ = breaker.admit(now: reopen)
        breaker.record(.failure, trial: true, now: reopen.advanced(by: .seconds(2)))
        #expect(breaker.state == .open(until: reopen.advanced(by: .seconds(62))))
    }

    @Test func aNeutralTrialLeavesTheNextCallToTry() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        trip(&breaker, at: t0)
        let reopen = t0.advanced(by: JudgeCircuitBreaker.cooldown)
        _ = breaker.admit(now: reopen)
        breaker.record(.neutral, trial: true, now: reopen)
        #expect(breaker.admit(now: reopen) == .proceed(trial: true))
    }

    @Test func aLateNonTrialOutcomeDoesNotDisturbAnOpenCircuit() {
        let t0 = ContinuousClock.now
        var breaker = JudgeCircuitBreaker()
        trip(&breaker, at: t0)
        let open = breaker.state
        // A call admitted before the trip answers after it.
        breaker.record(.success, trial: false, now: t0.advanced(by: .seconds(1)))
        breaker.record(.failure, trial: false, now: t0.advanced(by: .seconds(1)))
        #expect(breaker.state == open)
    }

    @Test func retryInRoundsUpToWholeSecondsForTheReason() {
        #expect(JudgeRuntime.retrySeconds(.milliseconds(59_100)) == 60)
        #expect(JudgeRuntime.retrySeconds(.seconds(60)) == 60)
        #expect(JudgeRuntime.retrySeconds(.zero) == 1)
    }
}

@Suite("Judge circuit around the live judge")
struct JudgeCircuitGateTests {
    @Test func anOpenCircuitSkipsTheJudgeWithoutRunningIt() {
        let clock = ManualClock()
        let circuit = JudgeCircuit(now: { clock.now })
        for _ in 0..<JudgeCircuitBreaker.tripCount {
            _ = JudgeRuntime.throughCircuit(circuit) { .late }
        }
        let ran = Mutex(false)
        let skipped = JudgeRuntime.throughCircuit(circuit) {
            ran.withLock { $0 = true }
            return .failed
        }
        guard case .circuitOpen(let retryIn) = skipped else {
            Issue.record("an open circuit must answer circuitOpen, got \(skipped)")
            return
        }
        #expect(retryIn == JudgeCircuitBreaker.cooldown)
        #expect(ran.withLock { $0 } == false)
        #expect(circuit.status == .open(retryIn: JudgeCircuitBreaker.cooldown))

        // Past the cooldown one trial reaches the judge; its verdict closes it.
        clock.advance(JudgeCircuitBreaker.cooldown)
        let trial = JudgeRuntime.throughCircuit(circuit) { .busy }
        guard case .busy = trial else {
            Issue.record("the trial must reach the judge, got \(trial)")
            return
        }
        // Busy behind a healthy holder is neutral: the next call is a trial too.
        #expect(circuit.status == .halfOpen)
        _ = JudgeRuntime.throughCircuit(circuit) { .failed }
        #expect(circuit.status == .open(retryIn: JudgeCircuitBreaker.cooldown))
    }

    @Test func whichOutcomesCountAgainstTheJudge() {
        #expect(JudgeRuntime.circuitOutcome(.late) == .failure)
        #expect(JudgeRuntime.circuitOutcome(.failed) == .failure)
        // A judge still loading is bounded by the loader; it is not an outage.
        #expect(JudgeRuntime.circuitOutcome(.warming) == .neutral)
        // Busy behind a healthy holder is a burst, not an outage. Busy
        // behind a stalled prediction comes back as `.late`.
        #expect(JudgeRuntime.circuitOutcome(.busy) == .neutral)
        #expect(JudgeRuntime.circuitOutcome(.unavailable("x")) == .neutral)
        #expect(JudgeRuntime.circuitOutcome(.circuitOpen(retryIn: .seconds(1))) == .neutral)
    }

    @Test func theLiveCircuitStartsClosed() {
        #expect(JudgeCircuit(now: { .now }).status == .closed)
    }
}
