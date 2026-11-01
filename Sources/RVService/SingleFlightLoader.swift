import Dispatch
import Foundation
import Synchronization

/// One cached, expensive-to-build value per key (a judge per bundle dir),
/// loaded at most once at a time.
///
/// Concurrent requests for the key being loaded join that one load instead
/// of starting their own (a CoreML judge is ~600 MB; N duplicate loads are
/// N × 600 MB). The load runs on a Dispatch queue, never on the caller or
/// the cooperative pool, so a caller can stop waiting at a deadline while
/// the load finishes in the background for the next request.
///
/// A failed load is cached against `stamp` (the bundle's model mtime), so a
/// repaired bundle retries and an unchanged broken one does not.
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
        case failed(key: URL, stamp: TimeInterval)
    }

    private enum Step {
        case done(Outcome)
        case join(Flight)
        case launch(Flight)
    }

    private let slot = Mutex<Slot>(.empty)

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
        slot.withLock { slot -> Step in
            switch slot {
            case .loaded(let loadedKey, let value) where loadedKey == key:
                return .done(.ready(value))
            case .failed(let failedKey, let failedStamp) where failedKey == key && failedStamp == stamp:
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
        DispatchQueue.global(qos: qos).async { [self] in
            let result = Result { try make() }
            slot.withLock { slot in
                // A newer key replaced this flight: its result is not cached.
                guard case .loading(_, let current) = slot, current === flight else { return }
                switch result {
                case .success(let value): slot = .loaded(key: key, value: value)
                case .failure: slot = .failed(key: key, stamp: stamp)
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
