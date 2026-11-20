#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVAnalytics
import RVDomain
import RVFileStore
import RVPolicy

/// A record the hook-local evaluator could not write within its budget.
package enum HookLocalDrop: String, Sendable, CaseIterable, Codable {
    /// A hash-chained `audit.jsonl` row.
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
/// decision rvd would have counted, and the rows it had to drop.
///
/// `<config>/hook-local-spool.jsonl` takes one batch per call in one
/// flocked `O_APPEND` write (`JSONLAppendLog`, no `fsync`), with a 50 ms
/// lock bound and a 4 MiB cap. A batch that cannot land costs one byte per
/// row in `<config>/hook-local-spool.uncounted`, written with no lock at
/// all, so a lost row is still counted. rvd drains both
/// (`ServiceRuntime.ingestHookLocalSpool`). Rows carry a decision kind or a
/// record name only: never command text, a path or a session.
///
/// Nothing here can change or hold a verdict: the evaluator writes the
/// spool after its answer is decided, and every failure is a count.
package enum HookLocalSpool {
    static let fileName = "hook-local-spool.jsonl"
    static let uncountedFileName = "hook-local-spool.uncounted"
    /// How long a batch waits for another writer's lock.
    static let lockTimeout: Duration = .milliseconds(50)
    /// Past this size a batch is counted, not written.
    static let maxBytes = 4 << 20
    /// Past this size a lost row is no longer counted either.
    static let maxUncountedBytes = 64 << 10
    /// How long rvd's drain waits for an evaluator's lock.
    static let drainLockTimeout: Duration = .seconds(1)

    package struct Batch: Sendable, Equatable {
        package var decision: AnalyticsDecisionKind?
        package var drops: [HookLocalDrop]

        package init(decision: AnalyticsDecisionKind?, drops: [HookLocalDrop]) {
            self.decision = decision
            self.drops = drops
        }

        var rowCount: Int { (decision == nil ? 0 : 1) + drops.count }
    }

    /// What one drain took out of the spool.
    package struct Drained: Sendable, Equatable {
        package var decisions: [AnalyticsDecisionKind: Int] = [:]
        package var drops: [HookLocalDrop: Int] = [:]
        /// Rows lost before they reached the spool, and spool lines that
        /// did not parse.
        package var lost = 0

        package init() {}

        var isEmpty: Bool { decisions.isEmpty && drops.isEmpty && lost == 0 }
    }

    private struct Row: Codable {
        var v = 1
        var decision: String?
        var dropped: String?
    }

    static func fileURL(home: HomeDirectory) -> URL {
        RVPolicyPaths.configDirectory(home: home).appendingPathComponent(fileName, isDirectory: false)
    }

    static func uncountedURL(home: HomeDirectory) -> URL {
        RVPolicyPaths.configDirectory(home: home).appendingPathComponent(uncountedFileName, isDirectory: false)
    }

    /// Appends `batch` as one write. Returns whether it landed; when it did
    /// not, each of its rows is counted in the uncounted file. An empty
    /// batch writes nothing.
    @discardableResult
    package static func write(_ batch: Batch, home: HomeDirectory) -> Bool {
        guard batch.rowCount > 0 else { return true }
        let url = fileURL(home: home)
        var rows: [Row] = []
        if let decision = batch.decision { rows.append(Row(decision: decision.rawValue)) }
        rows += batch.drops.map { Row(dropped: $0.rawValue) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows {
            guard let line = try? encoder.encode(row) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        if size(of: url) < maxBytes,
            (try? JSONLAppendLog.append(data, to: url, sync: false, lockTimeout: lockTimeout)) != nil
        {
            return true
        }
        countLost(batch.rowCount, home: home)
        return false
    }

    /// One byte per lost row, appended with no lock: `O_APPEND` keeps
    /// concurrent single writes whole, and a count needs nothing more.
    /// Refuses a symlink or a non-regular file, and stops at the cap.
    private static func countLost(_ rows: Int, home: HomeDirectory) {
        let url = uncountedURL(home: home)
        let fd = url.path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) < maxUncountedBytes else {
            return
        }
        let bytes = [UInt8](repeating: UInt8(ascii: "x"), count: rows)
        _ = bytes.withUnsafeBytes { posixWrite(fd, $0.baseAddress, $0.count) }
    }

    /// Takes everything out of the spool and the uncounted file. Cheap when
    /// both are empty (two `lstat`s). rvd calls it off the reply path.
    package static func drain(home: HomeDirectory) -> Drained {
        var drained = Drained()
        let url = fileURL(home: home)
        if size(of: url) > 0, let data = takeSpool(url) {
            parse(data, into: &drained)
        }
        drained.lost += takeUncounted(home: home)
        return drained
    }

    /// One `rvd.log` line (stderr) when a drain found dropped or lost rows;
    /// silent for decisions alone. Write errors are ignored, as for
    /// `AuditDropLog`: a full disk is one reason rows drop.
    static func report(_ drained: Drained, write: (String) -> Void = {
        try? FileHandle.standardError.write(contentsOf: Data($0.utf8))
    }) {
        guard drained.drops.isEmpty == false || drained.lost > 0 else { return }
        let drops = HookLocalDrop.allCases.compactMap { kind in
            drained.drops[kind].map { "\(kind.rawValue)=\($0)" }
        }
        var line = "rvd: the hook-local evaluator dropped records it could not write in its budget:"
        if drops.isEmpty == false { line += " " + drops.joined(separator: " ") }
        if drained.lost > 0 { line += " lost=\(drained.lost)" }
        write(line + "\n")
    }

    private static func parse(_ data: Data, into drained: inout Drained) {
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) where line.isEmpty == false {
            guard let row = try? decoder.decode(Row.self, from: Data(line)), row.v == 1 else {
                drained.lost += 1
                continue
            }
            if let decision = row.decision, row.dropped == nil, let kind = AnalyticsDecisionKind(rawValue: decision) {
                drained.decisions[kind, default: 0] += 1
            } else if let dropped = row.dropped, row.decision == nil, let drop = HookLocalDrop(rawValue: dropped) {
                drained.drops[drop, default: 0] += 1
            } else {
                drained.lost += 1
            }
        }
    }

    /// Reads and empties the spool under the writers' lock.
    private static func takeSpool(_ url: URL) -> Data? {
        let taken = JSONLAppendLog.withExclusiveLock(at: url, lockTimeout: drainLockTimeout) { locked -> Data? in
            let fd = locked.path.withCString { open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            // A spool past the cap is read up to it; the rest is dropped
            // with the truncate.
            let limit = min(Int(info.st_size), maxBytes)
            var data = Data(count: limit)
            let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, limit, 0) }
            guard read >= 0, ftruncate(fd, 0) == 0 else { return nil }
            return data.prefix(read)
        }
        return taken ?? nil
    }

    /// The uncounted file's size, taken by renaming it aside first, so a
    /// byte appended meanwhile lands in the next drain (or, rarely, in the
    /// file being counted).
    private static func takeUncounted(home: HomeDirectory) -> Int {
        let url = uncountedURL(home: home)
        let aside = url.appendingPathExtension("draining")
        var total = 0
        // A drain that stopped between rename and unlink left this behind.
        total += countAndRemove(aside)
        guard rename(url.path, aside.path) == 0 else { return total }
        total += countAndRemove(aside)
        return total
    }

    private static func countAndRemove(_ url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        unlink(url.path)
        guard (info.st_mode & S_IFMT) == S_IFREG else { return 0 }
        return min(Int(info.st_size), maxUncountedBytes)
    }

    /// The `lstat` size; 0 when missing.
    private static func size(of url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int(info.st_size)
    }
}

private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}
