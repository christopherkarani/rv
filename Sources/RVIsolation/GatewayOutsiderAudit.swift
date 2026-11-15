import Foundation

/// Audit records for refusals of connections from outside every runtime:
/// every malformed or timed-out head, whatever it holds, and any other
/// that presents no live placeholder. Any local process can send such heads
/// as fast as the outsider threads refuse them, naming any secret it likes,
/// and each record is appended and synced. The first in each interval is
/// written, with how many were left out since the one before it; the rest
/// are only counted, the last of them kept: the gateway writes it when it
/// stops, saying how many were left out before it. With no later refusal
/// and no stop, that count is not written. The drain is final: a refusal
/// from a connection still being refused as the gateway stops is written
/// as it comes, and there are at most as many as the gateway's connection
/// threads. A start bounds afresh. A refusal whose parsed head presents a
/// live placeholder, such as one spent from outside, is always written.
final class GatewayOutsiderAudit: @unchecked Sendable {
    static let interval: TimeInterval = 1

    private let lock = NSLock()
    private var written: DispatchTime?
    private var leftOut = 0
    private var last: SecretUseRecord?
    private var gap = GatewayOutsiderAudit.interval
    /// Set by `drain`, cleared by `reopen`: nothing is kept meanwhile.
    private var drained = false

    /// Test seam: seconds between records written.
    var interval: TimeInterval {
        get { lock.withLock { gap } }
        set { lock.withLock { gap = newValue } }
    }

    /// Nil when `record` is only counted (and kept for `drain`); otherwise
    /// the record to write, saying how many were left out before it.
    func admit(_ record: SecretUseRecord, at now: DispatchTime = .now()) -> SecretUseRecord? {
        lock.withLock {
            if drained { return record }
            if let written, now < written + gap {
                leftOut += 1
                last = record
                return nil
            }
            written = now
            defer { (leftOut, last) = (0, nil) }
            return Self.saying(leftOut, before: record)
        }
    }

    /// The last refusal left out, saying how many were left out before it;
    /// nil when none waits.
    /// Final until `reopen`.
    func drain() -> SecretUseRecord? {
        lock.withLock {
            drained = true
            guard let record = last else { return nil }
            defer { (leftOut, last) = (0, nil) }
            return Self.saying(leftOut - 1, before: record)
        }
    }

    /// A gateway starting: bounds afresh, with nothing of an earlier run.
    func reopen() {
        lock.withLock { (written, leftOut, last, drained) = (nil, 0, nil, false) }
    }

    private static func saying(_ count: Int, before record: SecretUseRecord) -> SecretUseRecord {
        guard count > 0 else { return record }
        var said = record
        said.reason = (record.reason ?? "") + " (\(count) more from outside the runtimes since the last record)"
        return said
    }
}
