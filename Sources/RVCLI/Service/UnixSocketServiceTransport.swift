#if os(Linux)
import Foundation
import RVIPC
import RVService

/// The Swift CLI's IPC transport on Linux: rvd's Unix socket, through a
/// peer-verified `UnixServiceConnection` (the peer must be the sibling `rvd`
/// running as the same user before any request, password included, is sent).
struct UnixSocketServiceTransport: ServiceTransport {
    private let connection: UnixServiceConnection

    init(socketPath: String) {
        self.connection = UnixServiceConnection(socketPath: socketPath)
    }

    /// The production socket, or nil when no path can be resolved.
    static func live() -> UnixSocketServiceTransport? {
        guard let url = try? UnixSocketPath.production() else { return nil }
        return UnixSocketServiceTransport(socketPath: url.path)
    }

    var oneShotEvaluateTimeoutMs: Int { 700 }

    func hello(clientSemver: String) async throws -> HelloAckView {
        let body = try IPCJSON.encode(Hello(protocolName: ProtocolVersion.name, clientSemver: clientSemver))
        let reply = try connection.roundTrip(body, timeoutMs: UnixServiceConnection.connectTimeoutMs)
        return HelloAckView(try IPCJSON.decode(HelloAck.self, from: reply))
    }

    func helloHookConsult(clientSemver: String) async throws -> HelloAckView {
        try await hello(clientSemver: clientSemver)
    }

    func send(_ body: Data) async throws -> Data {
        try connection.roundTrip(body, timeoutMs: oneShotEvaluateTimeoutMs)
    }

    func send(_ body: Data, timeoutMs: Int) async throws -> Data {
        try connection.roundTrip(body, timeoutMs: timeoutMs)
    }

    func sendHookConsult(_ body: Data, timeoutMs: Int) async throws -> Data {
        try connection.roundTrip(body, timeoutMs: timeoutMs)
    }

    func invalidate() {
        connection.invalidate()
    }
}
#endif
