#if canImport(XPC)
import Foundation
import Synchronization
@preconcurrency import XPC

public final class XPCEvaluateClient: Sendable {
    public let serviceName: String
    private let state: Mutex<ClientState>

    /// Never cancel/resume a connection while holding the state lock.
    private struct ClientState {
        var connection: xpc_connection_t?
        var opened = 0
    }

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
        self.state = Mutex(ClientState())
    }

    public var openedConnectionCount: Int {
        state.withLock { $0.opened }
    }

    public func invalidate() {
        let existing = state.withLock { state -> xpc_connection_t? in
            let current = state.connection
            state.connection = nil
            return current
        }
        if let existing {
            xpc_connection_cancel(existing)
        }
    }

    public func perform(_ body: Data) async throws -> Data {
        if Task.isCancelled {
            throw XPCEvaluateClientError.cancelled
        }
        let connection = try liveConnection()
        let once = OnceResume<Data>()
        let held = XPCHeld(connection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if once.install(continuation) {
                    return
                }
                if Task.isCancelled {
                    once.resume(throwing: XPCEvaluateClientError.cancelled)
                    return
                }
                let message = xpc_dictionary_create_empty()
                XPCIPCWire.set(body, on: message)
                xpc_connection_send_message_with_reply(held.object, message, nil) { reply in
                    let type = xpc_get_type(reply)
                    if type == XPC_TYPE_ERROR {
                        once.resume(throwing: XPCEvaluateClientError.connectFailed)
                        return
                    }
                    guard let data = XPCIPCWire.body(from: reply) else {
                        once.resume(throwing: XPCEvaluateClientError.connectFailed)
                        return
                    }
                    once.resume(returning: data)
                }
            }
        } onCancel: {
            once.resume(throwing: XPCEvaluateClientError.cancelled)
            self.invalidate()
        }
    }

    private func liveConnection() throws -> xpc_connection_t {
        if let existing = state.withLock({ $0.connection }) {
            return existing
        }

        let created = xpc_connection_create_mach_service(serviceName, nil, 0)
        let heldCreated = XPCHeld(created)
        xpc_connection_set_event_handler(created) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.forget(heldCreated.object)
            }
        }

        let winner = state.withLock { state -> xpc_connection_t in
            if let existing = state.connection {
                return existing
            }
            state.connection = created
            state.opened += 1
            return created
        }
        if winner !== created {
            xpc_connection_cancel(created)
            return winner
        }
        xpc_connection_resume(created)
        return created
    }

    private func forget(_ candidate: xpc_connection_t) {
        state.withLock {
            if $0.connection === candidate {
                $0.connection = nil
            }
        }
    }
}

public enum XPCEvaluateClientError: Error, Sendable, Equatable {
    case connectFailed
    case cancelled
}

final class OnceResume<T: Sendable>: Sendable {
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

    init() {
        state = Mutex(.idle)
    }

    init(_ continuation: CheckedContinuation<T, Error>) {
        state = Mutex(.armed(continuation))
    }

    /// Stores `continuation`, or resumes it immediately if cancel already landed.
    /// Returns `true` when the continuation is already settled.
    @discardableResult
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
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

    func resume(returning value: T) {
        let taken = state.withLock { state -> CheckedContinuation<T, Error>? in
            guard case .armed(let continuation) = state else { return nil }
            state = .finished
            return continuation
        }
        taken?.resume(returning: value)
    }

    func resume(throwing error: Error) {
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

