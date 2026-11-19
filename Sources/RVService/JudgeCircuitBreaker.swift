import Synchronization

/// Stops judged calls queueing on a judge that keeps failing them.
///
/// A Core ML prediction cannot be cancelled in-process. On Nov 19 single
/// predictions took 4-145 s for 92 minutes; every other judged call waited
/// for the model and came back busy. The breaker counts judge failures
/// (`late`, `failed`): `tripCount` inside `window` opens it, and while open
/// the judge is skipped for `cooldown` without touching the model or its
/// admission. Then one trial call runs (half-open): a verdict closes the
/// breaker, a failure reopens it for another cooldown.
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
    /// Failures inside `window` that open the breaker.
    static let tripCount = 3
    /// How far back failures count.
    static let window: Duration = .seconds(30)
    /// How long an open breaker skips the judge before a trial call.
    static let cooldown: Duration = .seconds(60)

    enum State: Sendable, Equatable {
        /// Judge runs; recent failure times, oldest first.
        case closed(failures: [ContinuousClock.Instant])
        /// Judge skipped until the instant.
        case open(until: ContinuousClock.Instant)
        /// Cooldown over: the next call is a trial; others skip while it runs.
        case halfOpen(trialInFlight: Bool)
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
        switch state {
        case .closed:
            return .proceed(trial: false)
        case .open(let until) where now < until:
            return .skip(retryIn: until - now)
        case .open, .halfOpen(trialInFlight: false):
            state = .halfOpen(trialInFlight: true)
            return .proceed(trial: true)
        case .halfOpen(trialInFlight: true):
            // The trial decides within one hook budget; say "shortly".
            return .skip(retryIn: .seconds(1))
        }
    }

    mutating func record(_ outcome: Outcome, trial: Bool, now: ContinuousClock.Instant) {
        if trial {
            guard case .halfOpen = state else { return }
            switch outcome {
            case .success: state = .closed(failures: [])
            case .failure: state = .open(until: now.advanced(by: Self.cooldown))
            case .neutral: state = .halfOpen(trialInFlight: false)
            }
            return
        }
        // A call admitted before the breaker opened may answer after; only
        // a closed breaker counts it.
        guard outcome == .failure, case .closed(let failures) = state else { return }
        let recent = failures.filter { now - $0 < Self.window } + [now]
        state = recent.count >= Self.tripCount
            ? .open(until: now.advanced(by: Self.cooldown))
            : .closed(failures: recent)
    }
}

/// The breaker every live judge call goes through, behind a lock.
final class JudgeCircuit: Sendable {
    static let live = JudgeCircuit(now: { .now })

    /// What doctor shows.
    enum Status: Sendable, Equatable {
        case closed
        case open(retryIn: Duration)
        case halfOpen
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
        switch breaker.withLock({ $0.state }) {
        case .closed: return .closed
        case .open(let until) where instant < until: return .open(retryIn: until - instant)
        case .open, .halfOpen: return .halfOpen
        }
    }
}
