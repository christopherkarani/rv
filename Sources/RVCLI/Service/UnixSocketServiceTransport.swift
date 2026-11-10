#if os(Linux)
import Foundation
import Glibc
import RVIPC
import RVService

/// The Swift CLI's IPC transport on Linux: rvd's Unix socket, through a
/// peer-verified `UnixServiceConnection` (the peer must be the sibling `rvd`
/// running as the same user before any request, password included, is sent).
struct UnixSocketServiceTransport: ServiceTransport {
    private let connection: UnixServiceConnection
    /// The socket is the uid-derived one (`UnixSocketPath.ClientSocket`).
    private let ownerRuntimeSocket: Bool

    init(socketPath: String, ownerRuntimeSocket: Bool = false) {
        self.connection = UnixServiceConnection(socketPath: socketPath)
        self.ownerRuntimeSocket = ownerRuntimeSocket
    }

    /// The production socket, resolved exactly like the C hook
    /// (`UnixSocketPath.clientSocket`), or nil when no path can be resolved.
    static func live() -> UnixSocketServiceTransport? {
        let xdg = getenv("XDG_RUNTIME_DIR").map { String(cString: $0) }
        guard let socket = UnixSocketPath.clientSocket(xdgRuntimeDir: xdg, uid: getuid()) else { return nil }
        return UnixSocketServiceTransport(socketPath: socket.url.path, ownerRuntimeSocket: socket.isOwnerRuntime)
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

    /// A connect miss (ENOENT / ECONNREFUSED) on the uid-derived socket is the
    /// only failure reported as `.connectFailed`, the hook's positive-absence
    /// signal; everything else propagates for `HookDaemonFallback.classify`.
    func sendHookConsult(_ body: Data, timeoutMs: Int) async throws -> Data {
        do {
            return try connection.roundTrip(body, timeoutMs: timeoutMs)
        } catch UnixServiceConnection.TransportFailure.connect(let code)
            where ownerRuntimeSocket && (code == ENOENT || code == ECONNREFUSED) {
            throw ServiceTransportError.connectFailed
        }
    }

    func invalidate() {
        connection.invalidate()
    }
}
#endif
