import Foundation
@preconcurrency import XPC

public final class XPCEvaluateClient: @unchecked Sendable {
    public let serviceName: String
    // lock guards connection and opened. Never cancel/resume while holding it.
    private let lock = NSLock()
    private var connection: xpc_connection_t?
    private var opened = 0

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
    }

    public var openedConnectionCount: Int {
        lock.withLock { opened }
    }

    public func invalidate() {
        let existing = lock.withLock { () -> xpc_connection_t? in
            let current = connection
            connection = nil
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
        if let existing = lock.withLock({ connection }) {
            return existing
        }

        let created = xpc_connection_create_mach_service(serviceName, nil, 0)
        let heldCreated = XPCHeld(created)
        xpc_connection_set_event_handler(created) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.forget(heldCreated.object)
            }
        }

        let winner = lock.withLock { () -> xpc_connection_t in
            if let existing = connection {
                return existing
            }
            connection = created
            opened += 1
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
        lock.withLock {
            if connection === candidate {
                connection = nil
            }
        }
    }
}

public enum XPCEvaluateClientError: Error, Sendable, Equatable {
    case connectFailed
    case cancelled
}

final class OnceResume<T: Sendable>: @unchecked Sendable {
    private enum State {
        case idle
        case pending(Error)
        case armed(CheckedContinuation<T, Error>)
        case finished
    }

    // lock guards state. Resume only a taken continuation, after unlock.
    private let lock = NSLock()
    private var state: State

    init() {
        state = .idle
    }

    init(_ continuation: CheckedContinuation<T, Error>) {
        state = .armed(continuation)
    }

    /// Stores `continuation`, or resumes it immediately if cancel already landed.
    /// Returns `true` when the continuation is already settled.
    @discardableResult
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        switch state {
        case .pending(let error):
            state = .finished
            lock.unlock()
            continuation.resume(throwing: error)
            return true
        case .idle:
            state = .armed(continuation)
            lock.unlock()
            return false
        case .armed, .finished:
            lock.unlock()
            return true
        }
    }

    func resume(returning value: T) {
        lock.lock()
        guard case .armed(let taken) = state else {
            lock.unlock()
            return
        }
        state = .finished
        lock.unlock()
        taken.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        switch state {
        case .armed(let taken):
            state = .finished
            lock.unlock()
            taken.resume(throwing: error)
        case .idle:
            state = .pending(error)
            lock.unlock()
        case .pending, .finished:
            lock.unlock()
        }
    }
}
