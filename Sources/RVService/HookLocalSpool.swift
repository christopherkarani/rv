#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVAnalytics
import RVDomain
import RVFileStore
import RVHistory
import RVPolicy

/// A record the hook-local evaluator could not write within its budget.
package enum HookLocalDrop: String, Sendable, CaseIterable, Codable {
    /// A hash-chained `audit.jsonl` row. A dropped row normally travels as
    /// a `HookLocalSpool.Audit` instead, and rvd appends it.
    case audit
    /// A `blocks.jsonl` denial-ledger row.
    case denialLedger = "denial-ledger"
    /// A `judge-log.jsonl` row.
    case judgeLog = "judge-log"
    /// An `exemption-drops.jsonl` row.
    case exemption
}

/// What the hook-local evaluator hands rvd after a final answer
/// (docs/architecture/hook-local-decide.md, "Effects"): the analytics
/// decision rvd would have counted, the rows it had to drop, and the
/// non-secret fields of any audit row it could not append, for rvd to
/// append in its place.
///
/// `<config>/hook-local-spool.jsonl` takes one batch per call in one
/// flocked `O_APPEND` write (`JSONLAppendLog`, no `fsync`), with at most a
/// 50 ms lock wait inside the evaluator's write deadline and a 4 MiB cap.
/// A batch that cannot land costs one byte per row in
/// `<config>/hook-local-spool.uncounted`, written with no lock at all (`a`
/// for an audit row, `x` for any other), so a lost row is still counted.
/// rvd drains both (`HookLocalSpoolDrainer`). Rows carry a decision kind, a
/// record name, or an audit row's rule, host, tool, category, redacted path
/// and time: never command text or a session.
///
/// Every open here is `O_NONBLOCK | O_NOFOLLOW` and accepts only a regular
/// file this user owns, so nothing planted at these paths can hang or
/// redirect a write. Nothing here can change or hold a verdict.
package enum HookLocalSpool {
    static let fileName = "hook-local-spool.jsonl"
    static let uncountedFileName = "hook-local-spool.uncounted"
    /// The longest a batch waits for another writer's lock (less when the
    /// evaluator's write deadline is closer).
    static let lockTimeout: Duration = .milliseconds(50)
    /// Past this size a batch is counted, not written.
    static let maxBytes = 4 << 20
    /// Past this size a lost row is no longer counted either.
    static let maxUncountedBytes = 64 << 10
    /// The uncounted file's byte for a lost audit row; any other byte is
    /// another lost row.
    static let lostAuditByte = UInt8(ascii: "a")
    static let lostRowByte = UInt8(ascii: "x")
    /// A redacted path longer than this is left out of a spooled audit row.
    static let maxPathBytes = 4096

    /// The fields of a `command.denied` or `command.observed` audit row the
    /// evaluator could not append (`GatedEvaluate.auditDenial`), for rvd to
    /// append marked `recorded_by: hook-local`.
    package struct Audit: Sendable, Equatable, Codable {
        var kind: String
        var rule: String
        var host: String
        var tool: String
        var category: String
        /// Home-redacted, as the audit row carries it; nil when empty or
        /// too long.
        var path: String?
        /// Observed rows only: `deny` or `ask`.
        var wouldBe: String?
        /// Seconds since 1970.
        var at: Double

        /// The audit event rvd appends, or nil when any field is not one
        /// the evaluator writes: the spool is a file, so it is read as
        /// untrusted input.
        package func event() -> AuditEvent? {
            let observed: Bool
            switch kind {
            case AuditEventKind.commandDenied.rawValue: observed = false
            case AuditEventKind.commandObserved.rawValue: observed = true
            default: return nil
            }
            guard RuleID(rawValue: rule) != nil, LedgerHost(rawValue: host) != nil,
                LedgerTool(rawValue: tool) != nil, LedgerCategory(rawValue: category) != nil,
                at.isFinite, at > 0
            else { return nil }
            if observed {
                guard let wouldBe, LedgerWouldBe(rawValue: wouldBe) != nil else { return nil }
            } else if wouldBe != nil {
                return nil
            }
            if let path {
                guard path.isEmpty == false, path.utf8.count <= HookLocalSpool.maxPathBytes else { return nil }
            }
            var detail = ["host": host, "tool": tool, "category": category, "recorded_by": "hook-local"]
            if let path { detail["path"] = path }
            if let wouldBe { detail["would_be"] = wouldBe }
            return AuditEvent(
                time: Date(timeIntervalSince1970: at),
                kind: observed ? .commandObserved : .commandDenied,
                decision: observed ? .info : .denied,
                subject: rule, agent: host == LedgerHost.tty.rawValue ? nil : host,
                source: AuditLedger.Source.audit.rawValue, detail: detail)
        }
    }

    package struct Batch: Sendable, Equatable {
        package var decision: AnalyticsDecisionKind?
        package var drops: [HookLocalDrop]
        package var audits: [Audit]

        package init(decision: AnalyticsDecisionKind?, drops: [HookLocalDrop], audits: [Audit] = []) {
            self.decision = decision
            self.drops = drops
            self.audits = audits
        }

        var lostAuditCount: Int { audits.count + drops.filter { $0 == .audit }.count }
        var lostOtherCount: Int { (decision == nil ? 0 : 1) + drops.filter { $0 != .audit }.count }
    }

    /// What one drain took out of the spool.
    package struct Drained: Sendable, Equatable {
        package var decisions: [AnalyticsDecisionKind: Int] = [:]
        package var drops: [HookLocalDrop: Int] = [:]
        /// Audit rows to append in the evaluator's place.
        package var audits: [Audit] = []
        /// Audit rows lost without their fields: counted in the uncounted
        /// file, or spooled with fields that did not validate.
        package var lostAudits = 0
        /// Other rows lost before they reached the spool, and spool lines
        /// that did not parse.
        package var lost = 0
        /// Spool bytes past the cap, dropped unread.
        package var truncatedBytes = 0

        package init() {}

        package var isEmpty: Bool {
            decisions.isEmpty && drops.isEmpty && audits.isEmpty && lostAudits == 0 && lost == 0
                && truncatedBytes == 0
        }
    }

    private struct Row: Codable {
        var v = 1
        var decision: String?
        var dropped: String?
        var audit: Audit?
    }

    static func fileURL(home: HomeDirectory) -> URL {
        RVPolicyPaths.configDirectory(home: home).appendingPathComponent(fileName, isDirectory: false)
    }

    static func uncountedURL(home: HomeDirectory) -> URL {
        RVPolicyPaths.configDirectory(home: home).appendingPathComponent(uncountedFileName, isDirectory: false)
    }

    /// Appends `batch` as one write, waiting at most `lockTimeout` for the
    /// lock (`.zero`: one non-blocking attempt). Returns whether it landed;
    /// when it did not, each of its rows is counted in the uncounted file.
    /// An empty batch writes nothing.
    @discardableResult
    package static func write(
        _ batch: Batch, home: HomeDirectory, lockTimeout: Duration = HookLocalSpool.lockTimeout
    ) -> Bool {
        guard batch.lostAuditCount + batch.lostOtherCount > 0 else { return true }
        let url = fileURL(home: home)
        var rows: [Row] = []
        if let decision = batch.decision { rows.append(Row(decision: decision.rawValue)) }
        rows += batch.drops.map { Row(dropped: $0.rawValue) }
        rows += batch.audits.map { Row(dropped: HookLocalDrop.audit.rawValue, audit: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows {
            guard let line = try? encoder.encode(row) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        if let size = ownedRegularSize(url), size < maxBytes,
            (try? JSONLAppendLog.append(data, to: url, sync: false, lockTimeout: max(.zero, lockTimeout))) != nil
        {
            return true
        }
        countLost(audits: batch.lostAuditCount, others: batch.lostOtherCount, home: home)
        return false
    }

    /// One byte per lost row, appended with no lock: `O_APPEND` keeps
    /// concurrent single writes whole, and a count needs nothing more.
    /// Refuses a symlink, a FIFO or other non-regular file, a file another
    /// user owns, and stops at the cap.
    private static func countLost(audits: Int, others: Int, home: HomeDirectory) {
        let url = uncountedURL(home: home)
        let fd = url.path.withCString {
            open($0, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, isOwnedRegular(info), Int(info.st_size) < maxUncountedBytes else { return }
        let bytes = [UInt8](repeating: lostAuditByte, count: audits) + [UInt8](repeating: lostRowByte, count: others)
        _ = bytes.withUnsafeBytes { posixWrite(fd, $0.baseAddress, $0.count) }
    }

    /// Takes everything out of the spool and the uncounted file without
    /// ever waiting: a spool another process holds is left for the next
    /// drain. Cheap when both are empty (two `lstat`s). Callers must not
    /// drain one home concurrently (`HookLocalSpoolDrainer` runs one at a
    /// time), or a leftover uncounted file could be counted twice.
    package static func drain(home: HomeDirectory) -> Drained {
        var drained = Drained()
        let url = fileURL(home: home)
        if let size = lstatSize(url), size > 0, let taken = takeSpool(url) {
            parse(taken.data, into: &drained)
            drained.truncatedBytes = taken.truncated
        }
        let lost = takeUncounted(home: home)
        drained.lostAudits += lost.audits
        drained.lost += lost.others
        return drained
    }

    private static func parse(_ data: Data, into drained: inout Drained) {
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) where line.isEmpty == false {
            guard let row = try? decoder.decode(Row.self, from: Data(line)), row.v == 1 else {
                drained.lost += 1
                continue
            }
            switch (row.decision, row.dropped, row.audit) {
            case (let decision?, nil, nil):
                if let kind = AnalyticsDecisionKind(rawValue: decision) {
                    drained.decisions[kind, default: 0] += 1
                } else {
                    drained.lost += 1
                }
            case (nil, HookLocalDrop.audit.rawValue?, let audit):
                if let audit, audit.event() != nil {
                    drained.audits.append(audit)
                } else {
                    drained.lostAudits += 1
                }
            case (nil, let dropped?, nil):
                if let drop = HookLocalDrop(rawValue: dropped) {
                    drained.drops[drop, default: 0] += 1
                } else {
                    drained.lost += 1
                }
            default:
                drained.lost += 1
            }
        }
    }

    /// Reads and empties the spool under the writers' lock, taken with one
    /// non-blocking attempt. Nil when another process holds it (or it
    /// cannot be opened); the rows stay for the next drain. A spool that is
    /// not this user's regular file is removed unread.
    private static func takeSpool(_ url: URL) -> (data: Data, truncated: Int)? {
        let taken = JSONLAppendLog.withExclusiveLock(at: url, lockTimeout: .zero) { locked -> (Data, Int)? in
            let fd = locked.path.withCString { open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            guard isOwnedRegular(info) else {
                unlink(locked.path)
                return nil
            }
            // Past the cap the spool is read up to it; the rest is
            // counted and dropped with the truncate.
            let size = Int(info.st_size)
            let limit = min(size, maxBytes)
            var data = Data(count: limit)
            var read = 0
            let complete = data.withUnsafeMutableBytes { buffer -> Bool in
                while read < limit {
                    let count = pread(fd, buffer.baseAddress! + read, limit - read, off_t(read))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return count == 0 }
                    read += count
                }
                return true
            }
            guard complete, ftruncate(fd, 0) == 0 else { return nil }
            return (data.prefix(read), size - read)
        }
        return (taken ?? nil).map { (data: $0.0, truncated: $0.1) }
    }

    /// The uncounted file's bytes, taken by renaming it aside first, so a
    /// byte appended meanwhile lands in the next drain (or, rarely, in the
    /// file being counted).
    private static func takeUncounted(home: HomeDirectory) -> (audits: Int, others: Int) {
        let url = uncountedURL(home: home)
        let aside = url.appendingPathExtension("draining")
        // A drain that stopped between rename and unlink left this behind.
        var total = countAndRemove(aside)
        guard rename(url.path, aside.path) == 0 else { return total }
        let more = countAndRemove(aside)
        total.audits += more.audits
        total.others += more.others
        return total
    }

    private static func countAndRemove(_ url: URL) -> (audits: Int, others: Int) {
        let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        defer { unlink(url.path) }
        guard fd >= 0 else { return (0, 0) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, isOwnedRegular(info) else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: min(Int(info.st_size), maxUncountedBytes))
        var read = 0
        while read < buffer.count {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + read, $0.count - read, off_t(read)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            read += count
        }
        let audits = buffer[0..<read].lazy.filter { $0 == lostAuditByte }.count
        return (audits, read - audits)
    }

    private static func isOwnedRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid()
    }

    /// The `lstat` size; nil when missing.
    private static func lstatSize(_ url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_size)
    }

    /// The spool's size when it is missing (0) or this user's regular file;
    /// nil for anything else, which the batch is then counted against.
    private static func ownedRegularSize(_ url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? 0 : nil }
        return isOwnedRegular(info) ? Int(info.st_size) : nil
    }

    /// The `rvd.log` message for one drain (without the timestamp), or nil
    /// when it found only decisions. `unappended` lists the rules of
    /// recovered audit rows rvd could not append either.
    static func reportMessage(_ drained: Drained, unappended: [String] = []) -> String? {
        var parts: [String] = []
        if drained.audits.isEmpty == false {
            var rules: [String] = []
            for audit in drained.audits where rules.contains(audit.rule) == false { rules.append(audit.rule) }
            let listed = rules.prefix(10).joined(separator: ", ") + (rules.count > 10 ? ", …" : "")
            parts.append("\(drained.audits.count) audit row(s) recovered and appended marked recorded_by=hook-local (\(listed))")
        }
        if unappended.isEmpty == false {
            parts.append("\(unappended.count) recovered audit row(s) could not be appended either")
        }
        if drained.lostAudits > 0 {
            parts.append("\(drained.lostAudits) audit row(s) lost without their fields (an audit.gap event records the count)")
        }
        let drops = HookLocalDrop.allCases.compactMap { kind in drained.drops[kind].map { "\(kind.rawValue)=\($0)" } }
        if drops.isEmpty == false { parts.append("dropped " + drops.joined(separator: " ")) }
        if drained.lost > 0 { parts.append("lost=\(drained.lost)") }
        if drained.truncatedBytes > 0 { parts.append("\(drained.truncatedBytes) spool bytes past the cap dropped unread") }
        guard parts.isEmpty == false else { return nil }
        return "rvd: the hook-local evaluator could not write every record in its budget: " + parts.joined(separator: "; ")
    }
}

private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}
