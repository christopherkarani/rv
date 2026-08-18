import Foundation

public final class XPCEvaluateClient: @unchecked Sendable {
    public let serviceName: String
    // lock guards connection and opened. Never invalidate/resume while holding it.
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var opened = 0

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
    }

    public var openedConnectionCount: Int {
        lock.withLock { opened }
    }

    public func invalidate() {
        let existing = lock.withLock { () -> NSXPCConnection? in
            let current = connection
            connection = nil
            return current
        }
        existing?.invalidate()
    }

    public func perform(_ body: Data) async throws -> Data {
        let connection = try liveConnection()
        let once = OnceResume<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if once.install(continuation) {
                    return
                }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    once.resume(throwing: error)
                }) as? RVEvaluateXPC else {
                    once.resume(throwing: XPCEvaluateClientError.connectFailed)
                    return
                }
                proxy.perform(body) { reply in
                    once.resume(returning: reply)
                }
            }
        } onCancel: {
            once.resume(throwing: XPCEvaluateClientError.cancelled)
            self.invalidate()
        }
    }

    private func liveConnection() throws -> NSXPCConnection {
        if let existing = lock.withLock({ connection }) {
            return existing
        }

        let created = NSXPCConnection(machServiceName: serviceName)
        created.remoteObjectInterface = NSXPCInterface(with: RVEvaluateXPC.self)
        created.invalidationHandler = { [weak self] in
            self?.forget(created)
        }

        let winner = lock.withLock { () -> NSXPCConnection in
            if let existing = connection {
                return existing
            }
            connection = created
            opened += 1
            return created
        }
        if winner !== created {
            created.invalidate()
            return winner
        }
        created.resume()
        return created
    }

    private func forget(_ candidate: NSXPCConnection) {
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
