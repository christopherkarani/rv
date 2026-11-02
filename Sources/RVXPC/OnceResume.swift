#if canImport(XPC)
import Synchronization

/// Resumes one checked continuation exactly once across an XPC reply
/// handler racing task cancellation. Cancel may land before `install`.
package final class OnceResume<T: Sendable>: Sendable {
    private enum State {
        case idle
        case pending(Error)
        case armed(CheckedContinuation<T, Error>)
        case finished
    }

    private enum InstallAction {
        case resumeThrowing(Error)
        case armed
        case settled
    }

    // A taken continuation is always resumed after the state lock is released.
    private let state: Mutex<State>

    package init() {
        state = Mutex(.idle)
    }

    package init(_ continuation: CheckedContinuation<T, Error>) {
        state = Mutex(.armed(continuation))
    }

    /// Stores `continuation`, or resumes it immediately if cancel already landed.
    /// Returns `true` when the continuation is already settled.
    @discardableResult
    package func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let action = state.withLock { state -> InstallAction in
            switch state {
            case .pending(let error):
                state = .finished
                return .resumeThrowing(error)
            case .idle:
                state = .armed(continuation)
                return .armed
            case .armed, .finished:
                return .settled
            }
        }
        switch action {
        case .resumeThrowing(let error):
            continuation.resume(throwing: error)
            return true
        case .armed:
            return false
        case .settled:
            return true
        }
    }

    package func resume(returning value: T) {
        let taken = state.withLock { state -> CheckedContinuation<T, Error>? in
            guard case .armed(let continuation) = state else { return nil }
            state = .finished
            return continuation
        }
        taken?.resume(returning: value)
    }

    package func resume(throwing error: Error) {
        let taken = state.withLock { state -> CheckedContinuation<T, Error>? in
            switch state {
            case .armed(let continuation):
                state = .finished
                return continuation
            case .idle:
                state = .pending(error)
                return nil
            case .pending, .finished:
                return nil
            }
        }
        taken?.resume(throwing: error)
    }
}
#endif
