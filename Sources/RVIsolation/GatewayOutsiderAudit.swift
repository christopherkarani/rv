import Foundation

/// Audit records for refusals of connections from outside every runtime
/// that present no live placeholder. Any local process can send such heads
/// as fast as the outsider threads refuse them, naming any secret it likes,
/// and each record is appended and synced. The first in each interval is
/// written, with how many were left out since the one before it; the rest
/// are only counted. A refusal that presents a live placeholder, such as
/// one spent from outside, is always written.
final class GatewayOutsiderAudit: @unchecked Sendable {
    static let interval: TimeInterval = 1

    private let lock = NSLock()
    private var written: DispatchTime?
    private var leftOut = 0
    private var gap = GatewayOutsiderAudit.interval

    /// Test seam: seconds between records written.
    var interval: TimeInterval {
        get { lock.withLock { gap } }
        set { lock.withLock { gap = newValue } }
    }

    /// Nil when this refusal is only counted; otherwise how many were left
    /// out before it.
    func admit(at now: DispatchTime = .now()) -> Int? {
        lock.withLock {
            if let written, now < written + gap {
                leftOut += 1
                return nil
            }
            written = now
            defer { leftOut = 0 }
            return leftOut
        }
    }
}
