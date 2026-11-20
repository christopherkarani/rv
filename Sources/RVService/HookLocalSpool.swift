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
/// file this user owns with one link, so nothing planted at these paths can
/// hang or redirect a write. Nothing here can change or hold a verdict.
package enum HookLocalSpool {
    static let fileName = "hook-local-spool.jsonl"
    static let uncountedFileName = "hook-local-spool.uncounted"
    /// The longest a batch waits for another writer's lock (less when the
    /// evaluator's write deadline is closer).
    static let lockTimeout: Duration = .milliseconds(50)
    /// Past this size a batch is counted, not written.
    static let maxBytes = 4 << 20
    /// What a drain reads past `maxBytes`: a batch that started below the
    /// cap may end above it.
    static let readSlack = 64 << 10
    /// Past this size a lost row is no longer counted either.
    static let maxUncountedBytes = 64 << 10
    /// The uncounted file's byte for a lost audit row; any other byte is
    /// another lost row.
    static let lostAuditByte = UInt8(ascii: "a")
    static let lostRowByte = UInt8(ascii: "x")
    /// A redacted path longer than this is left out of a spooled audit row.
    static let maxPathBytes = 4096
    /// A spooled rule id longer than this is not one the evaluator wrote.
    static let maxRuleBytes = 256
    /// A spooled audit row timed further than this from the drain is not
    /// chained: it is counted as lost.
    static let timeWindow: TimeInterval = 24 * 3600
    /// The most rows one drain takes, so rvd's other audit writers are not
    /// starved behind a full spool. The rest wait for the next drain.
    package static let maxRowsPerDrain = 2000

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

        /// The audit event rvd appends at `now`, or nil when any field is
        /// not one the evaluator writes, or the row is not from within a
        /// day of `now`: the spool is a file, so it is read as untrusted
        /// input.
        package func event(now: Date) -> AuditEvent? {
            let observed: Bool
            switch kind {
            case AuditEventKind.commandDenied.rawValue: observed = false
            case AuditEventKind.commandObserved.rawValue: observed = true
            default: return nil
            }
            guard rule.utf8.count <= HookLocalSpool.maxRuleBytes, RuleID(rawValue: rule) != nil,
                LedgerHost(rawValue: host) != nil, LedgerTool(rawValue: tool) != nil,
                LedgerCategory(rawValue: category) != nil,
                at.isFinite, abs(at - now.timeIntervalSince1970) <= HookLocalSpool.timeWindow
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
        /// Recovered audit rows, appended in the evaluator's place.
        package var audits: [Audit] = []
        /// Audit rows lost without their fields: counted in the uncounted
        /// file, or spooled with fields that did not validate. At least one
        /// whenever `atLeast` is set.
        package var lostAudits = 0
        /// Other rows lost before they reached the spool, and spool lines
        /// that did not parse.
        package var lost = 0
        /// Spool bytes past the read cap, dropped unread.
        package var truncatedBytes = 0
        /// The counts are a lower bound: the uncounted file was full, the
        /// spool was cut at the cap or held a line that did not parse, or a
        /// file planted at a spool path was removed.
        package var atLeast = false
        /// Rows left for the next drain: past the per-drain row cap, or
        /// from the first audit row that could not be appended on.
        package var kept = 0

        package init() {}

        package var isEmpty: Bool {
            decisions.isEmpty && drops.isEmpty && audits.isEmpty && lostAudits == 0 && lost == 0
                && truncatedBytes == 0 && atLeast == false && kept == 0
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

    /// Where a drain moves the spool before reading it; only rvd uses it.
    static func drainingURL(home: HomeDirectory) -> URL {
        fileURL(home: home).appendingPathExtension("draining")
    }

    static func uncountedURL(home: HomeDirectory) -> URL {
        RVPolicyPaths.configDirectory(home: home).appendingPathComponent(uncountedFileName, isDirectory: false)
    }

    /// Where a drain moves the uncounted file; counted one drain later.
    static func uncountedDrainingURL(home: HomeDirectory) -> URL {
        uncountedURL(home: home).appendingPathExtension("draining")
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
    /// user owns or with another link, and stops at the cap.
    package static func countLost(audits: Int, others: Int, home: HomeDirectory) {
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

    /// rvd's drain, never waiting for the evaluators' spool lock. It takes
    /// at most `maxRows` rows, in order: first those a previous drain left
    /// in the draining file, then the spool, which it renames aside under
    /// the writers' lock (one non-blocking attempt; a held lock leaves the
    /// rows for the next drain). Each recovered audit row goes to `append`;
    /// the first one that fails stops the drain, and it and every row after
    /// it stay in the draining file. That file is removed only once every
    /// row in it was taken. The uncounted file is renamed aside and counted
    /// by the next drain, by when a writer that opened it just before the
    /// rename has long finished its one write. Anything not this user's
    /// single-link regular file at these paths is removed unread and
    /// counted. Callers must not drain one home concurrently
    /// (`HookLocalSpoolDrainer` runs one at a time).
    package static func drain(
        home: HomeDirectory, now: Date, maxRows: Int = maxRowsPerDrain, append: (AuditEvent) -> Bool
    ) -> Drained {
        var drained = Drained()
        var rows = maxRows
        let spool = fileURL(home: home)
        let draining = drainingURL(home: home)
        removePlanted(spool, &drained)
        removePlanted(uncountedURL(home: home), &drained)
        var clear = consume(draining, now: now, rows: &rows, into: &drained, append: append)
        if clear, let size = lstatSize(spool), size > 0, takeSpool(spool, to: draining) {
            clear = consume(draining, now: now, rows: &rows, into: &drained, append: append)
        }
        takeUncounted(home: home, into: &drained)
        if drained.atLeast, drained.lostAudits == 0 { drained.lostAudits = 1 }
        return drained
    }

    /// One spool line.
    private enum Line {
        case decision(AnalyticsDecisionKind)
        case drop(HookLocalDrop)
        case audit(Audit, AuditEvent)
        case lostAudit
        case unreadable
    }

    private static func line(_ bytes: Data, now: Date) -> Line {
        guard let row = try? JSONDecoder().decode(Row.self, from: bytes), row.v == 1 else { return .unreadable }
        switch (row.decision, row.dropped, row.audit) {
        case (let decision?, nil, nil):
            return AnalyticsDecisionKind(rawValue: decision).map { .decision($0) } ?? .unreadable
        case (nil, HookLocalDrop.audit.rawValue?, let audit):
            guard let audit, let event = audit.event(now: now) else { return .lostAudit }
            return .audit(audit, event)
        case (nil, let dropped?, nil):
            return HookLocalDrop(rawValue: dropped).map { .drop($0) } ?? .unreadable
        default:
            return .unreadable
        }
    }

    /// Takes rows from the draining file at `url`; true when it is gone
    /// (absent, or every row taken and the file removed).
    private static func consume(
        _ url: URL, now: Date, rows: inout Int, into drained: inout Drained, append: (AuditEvent) -> Bool
    ) -> Bool {
        guard let (data, size) = readOwned(url, limit: maxBytes + readSlack, into: &drained) else { return true }
        if size > data.count {
            drained.truncatedBytes += size - data.count
            drained.atLeast = true
        }
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        var stop: Int?
        lines: while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let next = end == data.endIndex ? end : end + 1
            guard end > start else {
                start = next
                continue
            }
            guard rows > 0 else {
                stop = start
                break
            }
            // A tail with no newline is a torn write (or the cap's cut).
            let parsed = end == data.endIndex ? .unreadable : line(data[start..<end], now: now)
            switch parsed {
            case .decision(let kind): drained.decisions[kind, default: 0] += 1
            case .drop(let drop): drained.drops[drop, default: 0] += 1
            case .lostAudit: drained.lostAudits += 1
            case .unreadable:
                drained.lost += 1
                drained.atLeast = true
            case .audit(let audit, let event):
                guard append(event) else {
                    stop = start
                    break lines
                }
                drained.audits.append(audit)
            }
            rows -= 1
            start = next
        }
        guard let stop else {
            unlink(url.path)
            return true
        }
        let rest = data[stop...]
        if keep(rest, at: url) {
            drained.kept += rest.split(separator: newline).count
            return false
        }
        // The rest cannot be kept: counted, never appended twice.
        for bytes in rest.split(separator: newline) {
            if case .unreadable = line(Data(bytes), now: now) { drained.lost += 1 } else { drained.lostAudits += 1 }
        }
        drained.atLeast = true
        unlink(url.path)
        return true
    }

    /// Replaces the draining file with `rest` (write aside, then rename).
    private static func keep(_ rest: Data, at url: URL) -> Bool {
        let temporary = url.appendingPathExtension("tmp")
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        }
        guard fd >= 0 else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0, isOwnedRegular(info) else {
            close(fd)
            unlink(temporary.path)
            return false
        }
        var written = 0
        let complete = rest.withUnsafeBytes { buffer -> Bool in
            while written < buffer.count {
                let count = posixWrite(fd, buffer.baseAddress! + written, buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        close(fd)
        guard complete, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// Renames the spool aside under the writers' lock, taken with one
    /// non-blocking attempt: a writer opens the spool only while holding
    /// it, so every later batch lands in a new spool.
    private static func takeSpool(_ url: URL, to draining: URL) -> Bool {
        JSONLAppendLog.withExclusiveLock(at: url, lockTimeout: .zero) { locked in
            var info = stat()
            guard lstat(locked.path, &info) == 0, isOwnedRegular(info) else { return false }
            return rename(locked.path, draining.path) == 0
        } ?? false
    }

    /// Counts the uncounted file the previous drain moved aside, then moves
    /// the current one aside for the next drain.
    private static func takeUncounted(home: HomeDirectory, into drained: inout Drained) {
        let aside = uncountedDrainingURL(home: home)
        if let (data, size) = readOwned(aside, limit: maxUncountedBytes, into: &drained) {
            let audits = data.lazy.filter { $0 == lostAuditByte }.count
            drained.lostAudits += audits
            drained.lost += data.count - audits
            // Full: the writers stopped counting.
            if size >= maxUncountedBytes { drained.atLeast = true }
            unlink(aside.path)
        }
        var info = stat()
        guard lstat(aside.path, &info) != 0, errno == ENOENT else { return }
        _ = rename(uncountedURL(home: home).path, aside.path)
    }

    /// The bytes (at most `limit`) and size of this user's single-link
    /// regular file at `url`; nil when it is absent, or anything else,
    /// which is then removed unread and counted.
    private static func readOwned(_ url: URL, limit: Int, into drained: inout Drained) -> (Data, Int)? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, isOwnedRegular(info) else {
            if fd >= 0 { close(fd) }
            unlink(url.path)
            drained.atLeast = true
            return nil
        }
        defer { close(fd) }
        let size = Int(info.st_size)
        var data = Data(count: min(size, limit))
        var read = 0
        data.withUnsafeMutableBytes { buffer in
            while read < buffer.count {
                let count = pread(fd, buffer.baseAddress! + read, buffer.count - read, off_t(read))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                read += count
            }
        }
        return (data.prefix(read), size)
    }

    /// Removes anything at `url` that is not this user's single-link
    /// regular file (a symlink, FIFO or hard link someone planted), never
    /// following it, so the evaluators' writes work again; counted.
    private static func removePlanted(_ url: URL, _ drained: inout Drained) {
        var info = stat()
        guard lstat(url.path, &info) == 0, isOwnedRegular(info) == false else { return }
        unlink(url.path)
        drained.atLeast = true
    }

    private static func isOwnedRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
    }

    /// The `lstat` size; nil when missing.
    private static func lstatSize(_ url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_size)
    }

    /// The spool's size when it is missing (0) or this user's single-link
    /// regular file; nil for anything else, which the batch is then counted
    /// against.
    private static func ownedRegularSize(_ url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? 0 : nil }
        return isOwnedRegular(info) ? Int(info.st_size) : nil
    }

    /// The `rvd.log` message for one drain (without the timestamp), or nil
    /// when it found only decisions. `gapUnwritten`: the `audit.gap` event
    /// could not be appended, and its count went back to the uncounted file.
    static func reportMessage(_ drained: Drained, gapUnwritten: Bool = false) -> String? {
        var parts: [String] = []
        if drained.audits.isEmpty == false {
            var rules: [String] = []
            for audit in drained.audits where rules.contains(audit.rule) == false { rules.append(audit.rule) }
            let listed = rules.prefix(10).joined(separator: ", ") + (rules.count > 10 ? ", …" : "")
            parts.append("\(drained.audits.count) audit row(s) recovered and appended marked recorded_by=hook-local (\(listed))")
        }
        if drained.kept > 0 {
            parts.append("\(drained.kept) spooled row(s) left for the next drain")
        }
        if drained.lostAudits > 0 {
            let count = (drained.atLeast ? "at least " : "") + String(drained.lostAudits)
            parts.append(gapUnwritten
                ? "\(count) audit row(s) lost without their fields; the audit.gap event could not be appended and its count is kept for the next drain"
                : "\(count) audit row(s) lost without their fields (an audit.gap event records the count)")
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
