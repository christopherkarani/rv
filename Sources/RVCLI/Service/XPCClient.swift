import Foundation
import RVIPC
import RVService

public struct HelloAckView: Sendable, Equatable {
    public var protocolName: String
    public var serviceSemver: String
    public var ok: Bool
    public var skewReason: SkewReason?

    public init(protocolName: String, serviceSemver: String, ok: Bool, skewReason: SkewReason? = nil) {
        self.protocolName = protocolName
        self.serviceSemver = serviceSemver
        self.ok = ok
        self.skewReason = skewReason
    }

    public init(_ ack: HelloAck) {
        self.init(
            protocolName: ack.protocolName,
            serviceSemver: ack.serviceSemver,
            ok: ack.ok,
            skewReason: ack.skewReason
        )
    }
}

public enum ServiceTransportError: Error, Sendable, Equatable {
    case connectFailed
    case timeout
    case interrupted
    case decodeFailed
    case unexpected
}

public protocol ServiceTransport: Sendable {
    /// One-shot evaluate budget: connect (200) + request (500) = 700 ms.
    var oneShotEvaluateTimeoutMs: Int { get }
    func hello(clientSemver: String) async throws -> HelloAckView
    func send(_ body: Data) async throws -> Data
    func send(_ body: Data, timeoutMs: Int) async throws -> Data
    /// Drops the current transport connection after a failed or skewed handshake.
    func invalidate()
}

extension ServiceTransport {
    public var oneShotEvaluateTimeoutMs: Int { 700 }

    public func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        _ = timeoutMs
        return try await send(body)
    }
}

#if canImport(XPC)
public struct XPCServiceTransport: ServiceTransport, @unchecked Sendable {
    public static let serviceName = RVService.machServiceName
    public var connectTimeoutMs: Int
    public var requestTimeoutMs: Int
    private let session: XPCEvaluateClient

    public init(connectTimeoutMs: Int = 200, requestTimeoutMs: Int = 500) {
        self.connectTimeoutMs = connectTimeoutMs
        self.requestTimeoutMs = requestTimeoutMs
        self.session = XPCEvaluateClient(serviceName: Self.serviceName)
    }

    public func hello(clientSemver: String) async throws -> HelloAckView {
        let hello = Hello(protocolName: ProtocolVersion.name, clientSemver: clientSemver)
        let body = try IPCJSON.encode(hello)
        let reply = try await perform(body, timeoutMs: connectTimeoutMs)
        do {
            return HelloAckView(try IPCJSON.decode(HelloAck.self, from: reply))
        } catch {
            session.invalidate()
            throw ServiceTransportError.decodeFailed
        }
    }

    public var oneShotEvaluateTimeoutMs: Int {
        connectTimeoutMs + requestTimeoutMs
    }

    public func send(_ body: Data) async throws -> Data {
        try await perform(body, timeoutMs: requestTimeoutMs)
    }

    public func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        try await perform(body, timeoutMs: timeoutMs)
    }

    /// Drops the current XPC connection.
    public func invalidate() {
        session.invalidate()
    }

    var openedConnectionCount: Int { session.openedConnectionCount }

    private func perform(_ body: Data, timeoutMs: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.session.perform(body)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                throw ServiceTransportError.timeout
            }
            do {
                guard let first = try await group.next() else {
                    throw ServiceTransportError.connectFailed
                }
                group.cancelAll()
                return first
            } catch {
                session.invalidate()
                group.cancelAll()
                throw error
            }
        }
    }
}
#endif
