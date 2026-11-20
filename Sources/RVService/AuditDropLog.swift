import Foundation
import Synchronization

/// rvd's stderr line for an `audit.jsonl` (or `judge-log.jsonl`) row it
/// could not write. One line
/// per kind of row per minute at most: `rvd.log` rotates only at start, and
/// a broken log must not let an agent that keeps causing denies fill it.
final class AuditDropLog: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case ownerAction = "owner.action"
        case commandOverride = "command.override"
        case commandDenied = "command.denied"
        case commandObserved = "command.observed"
        case judgeLog = "judge-log"
    }

    static let interval: TimeInterval = 60
    static let shared = AuditDropLog()

    private let lastLogged = Mutex<[Kind: Date]>([:])
    private let write: @Sendable (String) -> Void

    /// The default writer ignores write errors: stderr is `rvd.log`, on the
    /// disk whose being full is a reason rows drop, and `write(_:)` traps on
    /// ENOSPC or EPIPE.
    init(write: @escaping @Sendable (String) -> Void = { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) }) {
        self.write = write
    }

    /// Logs that a `kind` row was dropped, unless a line for `kind` went out
    /// less than `interval` ago. `file` is the `audit.jsonl` that could not
    /// be written; nil when rvd has no home to keep one under.
    /// `consequence` says what rvd did instead. Returns whether it wrote.
    @discardableResult
    func report(_ kind: Kind, file: URL?, consequence: String, now: Date = Date()) -> Bool {
        let due = lastLogged.withLock { (last: inout [Kind: Date]) -> Bool in
            if let previous = last[kind], now >= previous, now.timeIntervalSince(previous) < Self.interval {
                return false
            }
            last[kind] = now
            return true
        }
        guard due else { return false }
        let target = file.map { "could not append to \($0.path)" } ?? "has no home directory to keep audit.jsonl in"
        write(RVDLogFile.line(
            "rvd: \(target); dropped a \(kind.rawValue) row, so \(consequence). "
                + "Check the file and its directory, then run `rv audit verify`. "
                + "Further drops of this kind are not logged for a minute",
            now: now))
        return true
    }
}
