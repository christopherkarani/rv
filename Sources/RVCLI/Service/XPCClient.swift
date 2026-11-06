import Foundation
import RVIPC
import RVService

public struct HelloAckView: Sendable, Equatable {
    public var protocolName: String
    public var serviceSemver: String
    public var status: HandshakeStatus

    public init(protocolName: String, serviceSemver: String, status: HandshakeStatus) {
        self.protocolName = protocolName
        self.serviceSemver = serviceSemver
        self.status = status
    }

    public init(_ ack: HelloAck) {
        self.init(
            protocolName: ack.protocolName,
            serviceSemver: ack.serviceSemver,
            status: ack.status
        )
    }
}

/// Closed set of ways a transport call can fail. Anything not explicitly
/// `timeout` or `unreachable` is non-softenable on the hook consult path.
public enum ServiceTransportFailure: Error, Sendable, Equatable {
    case timeout
    case unreachable
    /// The peer failed the daemon identity check.
    case untrusted
    /// Undecodable, empty, or otherwise unforeseen reply.
    case malformedReply
}

public protocol ServiceTransport: Sendable {
    /// One-shot evaluate budget: connect (200) + request (500) = 700 ms.
    var oneShotEvaluateTimeoutMs: Int { get }
    func hello(clientSemver: String) async throws(ServiceTransportFailure) -> HelloAckView
    func send(_ body: Data) async throws(ServiceTransportFailure) -> Data
    func send(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data
    /// Hook-consult send: daemon identity may use the sibling pin when no
    /// trust manifest is installed (see `XPCEvaluateClient.DaemonTrustMode`).
    func sendHookConsult(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data
    /// Hello over the hook-consult session: proves the daemon the way hooks
    /// do, so a healthy manifest-free install reads as reachable.
    func helloHookConsult(clientSemver: String) async throws(ServiceTransportFailure) -> HelloAckView
    /// Drops the current transport connection after a failed or skewed handshake.
    func invalidate()
}

extension ServiceTransport {
    public var oneShotEvaluateTimeoutMs: Int { 700 }

    public func send(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data {
        _ = timeoutMs
        return try await send(body)
    }

    public func sendHookConsult(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data {
        try await send(body, timeoutMs: timeoutMs)
    }

    public func helloHookConsult(clientSemver: String) async throws(ServiceTransportFailure) -> HelloAckView {
        try await hello(clientSemver: clientSemver)
    }
}

#if canImport(XPC)
public struct XPCServiceTransport: ServiceTransport {
    public static let serviceName = RVService.machServiceName
    public var connectTimeoutMs: Int
    public var requestTimeoutMs: Int
    private let session: XPCEvaluateClient
    private let hookSession: XPCEvaluateClient

    /// `hookSiblingDaemonPath` pins the hook-consult session to a specific
    /// `rvd` (doctor/status pass `~/.local/bin/rvd`, the binary hooks pin);
    /// nil pins the `rvd` beside the running executable.
    public init(
        connectTimeoutMs: Int = 200,
        requestTimeoutMs: Int = 500,
        hookSiblingDaemonPath: String? = nil
    ) {
        self.connectTimeoutMs = connectTimeoutMs
        self.requestTimeoutMs = requestTimeoutMs
        self.session = XPCEvaluateClient(serviceName: Self.serviceName)
        self.hookSession = XPCEvaluateClient(
            serviceName: Self.serviceName,
            daemonTrust: .hookConsult,
            siblingDaemonPath: hookSiblingDaemonPath
        )
    }

    public func hello(clientSemver: String) async throws(ServiceTransportFailure) -> HelloAckView {
        let hello = Hello(protocolName: ProtocolVersion.name, clientSemver: clientSemver)
        let reply = try await perform(try Self.encode(hello), timeoutMs: connectTimeoutMs)
        do {
            return HelloAckView(try IPCJSON.decode(HelloAck.self, from: reply))
        } catch {
            session.invalidate()
            throw .malformedReply
        }
    }

    public func helloHookConsult(clientSemver: String) async throws(ServiceTransportFailure) -> HelloAckView {
        let hello = Hello(protocolName: ProtocolVersion.name, clientSemver: clientSemver)
        let reply = try await perform(try Self.encode(hello), timeoutMs: connectTimeoutMs, on: hookSession)
        do {
            return HelloAckView(try IPCJSON.decode(HelloAck.self, from: reply))
        } catch {
            hookSession.invalidate()
            throw .malformedReply
        }
    }

    public var oneShotEvaluateTimeoutMs: Int {
        connectTimeoutMs + requestTimeoutMs
    }

    public func send(_ body: Data) async throws(ServiceTransportFailure) -> Data {
        try await perform(body, timeoutMs: requestTimeoutMs)
    }

    public func send(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data {
        try await perform(body, timeoutMs: timeoutMs)
    }

    public func sendHookConsult(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data {
        try await perform(body, timeoutMs: timeoutMs, on: hookSession)
    }

    /// Drops the current XPC connection.
    public func invalidate() {
        session.invalidate()
        hookSession.invalidate()
    }

    var openedConnectionCount: Int { session.openedConnectionCount }

    private static func encode(_ hello: Hello) throws(ServiceTransportFailure) -> Data {
        do {
            return try IPCJSON.encode(hello)
        } catch {
            throw .malformedReply
        }
    }

    private func perform(_ body: Data, timeoutMs: Int) async throws(ServiceTransportFailure) -> Data {
        try await perform(body, timeoutMs: timeoutMs, on: session)
    }

    /// The single place untyped errors from the XPC client and task group
    /// become `ServiceTransportFailure` (see `transportFailure(from:)`).
    private func perform(
        _ body: Data, timeoutMs: Int, on client: XPCEvaluateClient
    ) async throws(ServiceTransportFailure) -> Data {
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await client.perform(body)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    throw ServiceTransportFailure.timeout
                }
                do {
                    guard let first = try await group.next() else {
                        throw ServiceTransportFailure.unreachable
                    }
                    group.cancelAll()
                    return first
                } catch {
                    client.invalidate()
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            throw Self.transportFailure(from: error)
        }
    }

    /// Maps an untyped XPC client or task-group error; anything unforeseen
    /// (e.g. a `DecodingError` from a garbage hello ack) is `malformedReply`.
    static func transportFailure(from error: any Error) -> ServiceTransportFailure {
        switch error {
        case let failure as ServiceTransportFailure:
            failure
        case XPCEvaluateClientError.authenticationFailed:
            .untrusted
        case XPCEvaluateClientError.connectFailed, XPCEvaluateClientError.cancelled:
            .unreachable
        case XPCEvaluateClientError.malformedReply:
            .malformedReply
        case is CancellationError:
            // Only the caller's own cancellation (the timeout sleep); never peer bytes.
            .unreachable
        default:
            .malformedReply
        }
    }
}
#endif
