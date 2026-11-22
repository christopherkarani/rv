#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

/// Per-connection bounds shared by the Darwin and Linux socket listeners.
///
/// Clients hold no persistent connections (`sdk/WIRE.md` §6): a call is one
/// hello plus one request inside a 700 ms budget, then the client hangs up.
/// The receive timeout only bounds the wait for the client's next frame —
/// never the service's own work — so it sits far above that budget and only
/// reaps peers that connect and go silent.
public struct UnixConnectionLimits: Sendable, Equatable {
    public static let defaultMaxConnections = 64
    public static let defaultReceiveTimeoutSeconds = 30
    public static let defaultSendTimeoutSeconds = 10

    public static let standard = UnixConnectionLimits(
        maxConnections: defaultMaxConnections,
        receiveTimeoutSeconds: defaultReceiveTimeoutSeconds
    )

    /// Connections served at once. Accepts beyond this are closed unread.
    public let maxConnections: Int
    /// `SO_RCVTIMEO` on each accepted connection.
    public let receiveTimeoutSeconds: Int
    /// `SO_SNDTIMEO` on each accepted connection: how long a reply may wait
    /// for a peer that stopped reading. A client reads its reply at once,
    /// so this only reaps a peer that pipelines requests (say `events`
    /// polls) and never reads; its connection closes and frees the slot.
    public let sendTimeoutSeconds: Int

    public init(
        maxConnections: Int,
        receiveTimeoutSeconds: Int,
        sendTimeoutSeconds: Int = UnixConnectionLimits.defaultSendTimeoutSeconds
    ) {
        self.maxConnections = max(1, maxConnections)
        self.receiveTimeoutSeconds = max(1, receiveTimeoutSeconds)
        self.sendTimeoutSeconds = max(1, sendTimeoutSeconds)
    }

    /// Applies the receive and send timeouts to an accepted connection. A
    /// failed `setsockopt` is reported so the caller drops the connection
    /// rather than serving one that could park forever.
    func applyTimeouts(to fd: Int32) -> Bool {
        var receive = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        var send = timeval(tv_sec: sendTimeoutSeconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, size) == 0
            && setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, size) == 0
    }
}

/// Counts live connections against `UnixConnectionLimits.maxConnections`.
final class UnixConnectionSlots: Sendable {
    private let limit: Int
    private let live = Mutex<Int>(0)

    init(limit: Int) {
        self.limit = limit
    }

    /// Claims a slot; `false` when the listener is already at its cap.
    func acquire() -> Bool {
        live.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() {
        live.withLock { $0 = max(0, $0 - 1) }
    }
}
