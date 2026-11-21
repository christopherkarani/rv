import Synchronization

/// Stops judged calls queueing on a judge that keeps failing them.
///
/// A Core ML prediction cannot be cancelled in-process. On Nov 19 single
/// predictions took 4-145 s for 92 minutes; every other judged call waited
/// for the model and came back busy. The breaker counts judge failures
/// (`late`, `failed`): `tripCount` inside `window` opens it, and while open
/// the judge is skipped for `cooldown` without touching the model or its
/// admission. Then one trial call runs (half-open): a verdict closes the
/// breaker, a failure reopens it for another cooldown. A trial still out
/// after `trialLimit` counts as a failure, so a caller stuck behind a
/// wedged prediction cannot hold the breaker half-open.
///
/// A verdict while closed clears the failure window: the breaker opens on
/// consecutive failures, not on the occasional slow prediction a working
/// judge also has (p99 19 s).
///
/// A skipped judge is not an allow: the caller fails it closed exactly as
/// it fails a busy judge (`JudgeRuntime.failClosed`), to review in enforce
/// and to a would-be review in observe.
///
/// Outcomes that do not count (`neutral`): a load still warming (the
/// loader bounds it, and counting it would trip the breaker on every rvd
/// start and keep the judge off for a minute after the model is ready), a
/// busy turn-away behind a healthy prediction (a burst, not an outage; a
/// turn-away behind a stalled prediction comes back `late`), and an
/// unavailable bundle (packs-only, reported by doctor).
///
/// Pure value; `JudgeCircuit` holds the live one behind a lock with an
/// injected clock.
struct JudgeCircuitBreaker: Sendable, Equatable {
    /// Consecutive failures inside `window` that open the breaker.
    static let tripCount = 3
    /// How far back failures count.
    static let window: Duration = .seconds(30)
    /// How long an open breaker skips the judge before a trial call.
    static let cooldown: Duration = .seconds(60)
    /// How long a trial may stay out before it counts as a failure: every
    /// judged rvd call is bounded by one hook budget.
    static let trialLimit: Duration = HookDeadline.budget

    enum State: Sendable, Equatable {
        /// Judge runs; failure times since the last verdict, oldest first.
        case closed(failures: [ContinuousClock.Instant])
        /// Judge skipped until the instant.
        case open(until: ContinuousClock.Instant)
        /// Cooldown over: the next call is a trial; others skip while it
        /// runs. `trialStarted` is nil until the trial is handed out.
        case halfOpen(trialStarted: ContinuousClock.Instant?)
    }

    enum Admission: Sendable, Equatable {
        /// Run the judge. `trial` marks the one half-open call; its outcome
        /// decides the breaker.
        case proceed(trial: Bool)
        /// Skip the judge; the next trial is about `retryIn` away.
        case skip(retryIn: Duration)
    }

    enum Outcome: Sendable, Equatable {
        case success
        case failure
        case neutral
    }

    private(set) var state: State = .closed(failures: [])

    mutating func admit(now: ContinuousClock.Instant) -> Admission {
        state = Self.settled(state, now: now)
        switch state {
        case .closed:
            return .proceed(trial: false)
        case .open(let until) where now < until:
            return .skip(retryIn: until - now)
        case .open, .halfOpen(trialStarted: nil):
            state = .halfOpen(trialStarted: now)
            return .proceed(trial: true)
        case .halfOpen(let started?):
            return .skip(retryIn: max(started.advanced(by: Self.trialLimit) - now, .seconds(1)))
        }
    }

    /// The state once an overdue trial is counted as the failure it is:
    /// reopened from the moment the trial ran out.
    static func settled(_ state: State, now: ContinuousClock.Instant) -> State {
        guard case .halfOpen(let started?) = state, now - started >= trialLimit else { return state }
        return .open(until: started.advanced(by: trialLimit + cooldown))
    }

    /// A trial's outcome only lands while that trial is still out; one that
    /// overran `trialLimit` was already counted as a failure. (A trial that
    /// outlives a whole cooldown and answers during the next trial is taken
    /// for it; rvd bounds every judged call by one hook budget, so it
    /// cannot.)
    mutating func record(_ outcome: Outcome, trial: Bool, now: ContinuousClock.Instant) {
        state = Self.settled(state, now: now)
        if trial {
            guard case .halfOpen(_?) = state else { return }
            switch outcome {
            case .success: state = .closed(failures: [])
            case .failure: state = .open(until: now.advanced(by: Self.cooldown))
            case .neutral: state = .halfOpen(trialStarted: nil)
            }
            return
        }
        // A call admitted before the breaker opened may answer after; only
        // a closed breaker counts it.
        guard case .closed(let failures) = state else { return }
        switch outcome {
        case .success:
            state = .closed(failures: [])
        case .neutral:
            break
        case .failure:
            let recent = failures.filter { now - $0 < Self.window } + [now]
            state = recent.count >= Self.tripCount
                ? .open(until: now.advanced(by: Self.cooldown))
                : .closed(failures: recent)
        }
    }
}

/// The breaker every live judge call goes through, behind a lock.
final class JudgeCircuit: Sendable {
    static let live = JudgeCircuit(now: { .now })

    /// What doctor shows.
    enum Status: Sendable, Equatable {
        case closed
        case open(retryIn: Duration)
        /// `trialInFlight`: a trial call is running now; otherwise the next
        /// judged call is the trial.
        case halfOpen(trialInFlight: Bool)
    }

    private let breaker = Mutex(JudgeCircuitBreaker())
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
    }

    func admit() -> JudgeCircuitBreaker.Admission {
        let instant = now()
        return breaker.withLock { $0.admit(now: instant) }
    }

    func record(_ outcome: JudgeCircuitBreaker.Outcome, trial: Bool) {
        let instant = now()
        breaker.withLock { $0.record(outcome, trial: trial, now: instant) }
    }

    var status: Status {
        let instant = now()
        switch JudgeCircuitBreaker.settled(breaker.withLock { $0.state }, now: instant) {
        case .closed: return .closed
        case .open(let until) where instant < until: return .open(retryIn: until - instant)
        case .open, .halfOpen(trialStarted: nil): return .halfOpen(trialInFlight: false)
        case .halfOpen(trialStarted: _?): return .halfOpen(trialInFlight: true)
        }
    }
}
