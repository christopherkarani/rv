import Dispatch
import Foundation
import Synchronization

/// One cached, expensive-to-build value per key (a judge per bundle dir),
/// loaded at most once at a time.
///
/// Concurrent requests for the key being loaded join that one load instead
/// of starting their own (a CoreML judge is ~600 MB; N duplicate loads are
/// N × 600 MB). The load runs on a private Dispatch queue, never on the
/// caller or the cooperative pool, so a caller can stop waiting at a deadline while
/// the load finishes in the background for the next request.
///
/// A failed load is cached against `stamp` (the bundle's model mtime), so a
/// repaired bundle retries at once, and for `retryFailuresAfter` only, so a
/// transient failure (memory pressure during prewarm) does not leave the
/// daemon judge-less for its whole lifetime.
final class SingleFlightLoader<Value: AnyObject & Sendable>: Sendable {
    enum Outcome {
        case ready(Value)
        /// This caller waited on the load that failed.
        case failed(any Error)
        /// An earlier load of this key at this stamp failed.
        case cachedFailure
        /// The load is still running past the caller's wait.
        case warming
    }

    private final class Flight: Sendable {
        private let group = DispatchGroup()
        private let result = Mutex<Result<Value, any Error>?>(nil)

        init() { group.enter() }

        func finish(_ outcome: Result<Value, any Error>) {
            result.withLock { $0 = outcome }
            group.leave()
        }

        /// Nil when `wait` elapsed first. A nil `wait` waits for completion.
        func wait(_ wait: Duration?) -> Result<Value, any Error>? {
            if let wait {
                guard group.wait(timeout: .now() + dispatchInterval(wait)) == .success else {
                    return nil
                }
            } else {
                group.wait()
            }
            return result.withLock { $0 }
        }
    }

    private enum Slot {
        case empty
        case loading(key: URL, flight: Flight)
        case loaded(key: URL, value: Value)
        case failed(key: URL, stamp: TimeInterval, at: ContinuousClock.Instant)
    }

    private enum Step {
        case done(Outcome)
        case join(Flight)
        case launch(Flight)
    }

    /// A failed load is retried after this long even if the stamp is unchanged.
    static var defaultFailureRetry: Duration { .seconds(60) }

    private let slot = Mutex<Slot>(.empty)
    private let retryFailuresAfter: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        retryFailuresAfter: Duration = SingleFlightLoader.defaultFailureRetry,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.retryFailuresAfter = retryFailuresAfter
        self.now = now
    }

    /// Returns the value for `key`, joining or starting its load, waiting at
    /// most `wait` (nil: until the load completes).
    func value(
        key: URL,
        stamp: TimeInterval,
        wait: Duration?,
        qos: DispatchQoS.QoSClass = .userInitiated,
        make: @escaping @Sendable () throws -> Value
    ) -> Outcome {
        switch step(key: key, stamp: stamp) {
        case .done(let outcome):
            return outcome
        case .join(let flight):
            return Self.outcome(flight.wait(wait))
        case .launch(let flight):
            launch(flight, key: key, stamp: stamp, qos: qos, make: make)
            return Self.outcome(flight.wait(wait))
        }
    }

    /// Starts the load for `key` in the background unless it is already
    /// loaded, loading, or failed at this stamp. Never blocks.
    func prewarm(
        key: URL,
        stamp: TimeInterval,
        qos: DispatchQoS.QoSClass = .utility,
        make: @escaping @Sendable () throws -> Value
    ) {
        if case .launch(let flight) = step(key: key, stamp: stamp) {
            launch(flight, key: key, stamp: stamp, qos: qos, make: make)
        }
    }

    private func step(key: URL, stamp: TimeInterval) -> Step {
        let current = self.now()
        return slot.withLock { slot -> Step in
            switch slot {
            case .loaded(let loadedKey, let value) where loadedKey == key:
                return .done(.ready(value))
            case .failed(let failedKey, let failedStamp, let failedAt)
                where failedKey == key && failedStamp == stamp
                    && current < failedAt.advanced(by: retryFailuresAfter):
                return .done(.cachedFailure)
            case .loading(let loadingKey, let flight) where loadingKey == key:
                return .join(flight)
            default:
                let flight = Flight()
                slot = .loading(key: key, flight: flight)
                return .launch(flight)
            }
        }
    }

    private func launch(
        _ flight: Flight,
        key: URL,
        stamp: TimeInterval,
        qos: DispatchQoS.QoSClass,
        make: @escaping @Sendable () throws -> Value
    ) {
        // A private queue, not `global`: global queues share the
        // cooperative pool's constrained thread budget, so a saturated pool
        // could keep the load itself from ever starting.
        DispatchQueue(label: "rv.judge-load", qos: DispatchQoS(qosClass: qos, relativePriority: 0)).async { [self] in
            let result = Result { try make() }
            let finishedAt = self.now()
            slot.withLock { slot in
                // A newer key replaced this flight: its result is not cached.
                guard case .loading(_, let current) = slot, current === flight else { return }
                switch result {
                case .success(let value): slot = .loaded(key: key, value: value)
                case .failure: slot = .failed(key: key, stamp: stamp, at: finishedAt)
                }
            }
            flight.finish(result)
        }
    }

    private static func outcome(_ result: Result<Value, any Error>?) -> Outcome {
        switch result {
        case .none: return .warming
        case .some(.success(let value)): return .ready(value)
        case .some(.failure(let error)): return .failed(error)
        }
    }
}

/// `Duration` as a Dispatch interval; overflow reads as `.never`.
func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard nanoseconds.overflow == false else { return .never }
    let total = nanoseconds.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000)
    guard total.overflow == false, total.partialValue <= Int64(Int.max) else { return .never }
    return .nanoseconds(Int(max(0, total.partialValue)))
}
