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

    public static let standard = UnixConnectionLimits(
        maxConnections: defaultMaxConnections,
        receiveTimeoutSeconds: defaultReceiveTimeoutSeconds
    )

    /// Connections served at once. Accepts beyond this are closed unread.
    public let maxConnections: Int
    /// `SO_RCVTIMEO` on each accepted connection.
    public let receiveTimeoutSeconds: Int

    public init(maxConnections: Int, receiveTimeoutSeconds: Int) {
        self.maxConnections = max(1, maxConnections)
        self.receiveTimeoutSeconds = max(1, receiveTimeoutSeconds)
    }

    /// Applies the receive timeout to an accepted connection. A failed
    /// `setsockopt` is reported so the caller drops the connection rather
    /// than serving one that could park forever.
    func applyReceiveTimeout(to fd: Int32) -> Bool {
        var timeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        return setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
        ) == 0
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
