#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// How fast a client must take in its answer while the gateway has bytes
/// waiting for it. The socket's send timeout starts again after every
/// partial write, so a client taking a few bytes before each timeout would
/// otherwise hold its slot, its threads, its session and its upstream
/// connection for as long as it liked. Only time spent in a write counts:
/// a stream with nothing to send, such as SSE between events, waits as
/// long as its upstream does. One response writer uses it, under its lock.
final class GatewayClientPace: @unchecked Sendable {
    /// Bytes a client must take in over each `window` of waiting.
    static let minimumBytes = 16 * 1024

    private let window: TimeInterval
    private let minimumBytes: Int
    private var waited: TimeInterval = 0
    private var taken = 0

    init(window: TimeInterval, minimumBytes: Int = GatewayClientPace.minimumBytes) {
        self.window = window
        self.minimumBytes = minimumBytes
    }

    /// Writes all of `bytes`. False when a write fails, or when the client
    /// took in fewer than `minimumBytes` over the last `window` seconds the
    /// gateway spent writing to it; the connection is then to be cut.
    func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var written = 0
        while written < bytes.count {
            let started = DispatchTime.now().uptimeNanoseconds
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base + written, raw.count - written, GatewaySocket.sendFlags)
            }
            let failure = errno
            let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            if n > 0 { written += n }
            guard took(max(n, 0), over: elapsed) else { return false }
            if n < 0, failure == EINTR { continue }
            guard n > 0 else { return false }
        }
        return true
    }

    /// Counts one write; false once a full window has passed with too little taken in.
    private func took(_ count: Int, over elapsed: TimeInterval) -> Bool {
        waited += elapsed
        taken += count
        guard waited >= window else { return true }
        defer { (waited, taken) = (0, 0) }
        return taken >= minimumBytes
    }
}
