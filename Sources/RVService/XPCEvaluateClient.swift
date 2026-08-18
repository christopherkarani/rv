import Foundation

public final class XPCEvaluateClient: @unchecked Sendable {
    public let serviceName: String
    nonisolated(unsafe) private var connection: NSXPCConnection?
    nonisolated(unsafe) private var opened = 0

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
    }

    public var openedConnectionCount: Int { opened }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    public func perform(_ body: Data) async throws -> Data {
        let connection = try liveConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceResume(continuation)
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
    }

    private func liveConnection() throws -> NSXPCConnection {
        if let connection {
            return connection
        }
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: RVEvaluateXPC.self)
        connection.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        connection.resume()
        self.connection = connection
        opened += 1
        return connection
    }
}

public enum XPCEvaluateClientError: Error, Sendable, Equatable {
    case connectFailed
}

final class OnceResume<T: Sendable>: @unchecked Sendable {
    nonisolated(unsafe) private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
