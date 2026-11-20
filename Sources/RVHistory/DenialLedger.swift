import Foundation
import RVFileStore
import Synchronization

/// JSONL denial store. Newest-first records. Prunes to 200 rows or 7 days.
///
/// Reads always return at most `RVHistory.maxRows` rows inside
/// `RVHistory.maxAge`. The file itself may hold up to
/// `RVHistory.maxRows + compactionSlack` rows between rewrites: a deny
/// appends one line, and the file is rewritten (pruned to the cap, rows past
/// the age window dropped) only when it outgrows that slack, holds a row past
/// the age window, or was changed by another writer.
public struct DenialLedger: Sendable {
    public var fileURL: URL

    /// Rows past `RVHistory.maxRows` the file may hold before an append
    /// rewrites it down to the cap. Reads still cap at `RVHistory.maxRows`.
    public static let compactionSlack = 50

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(configDirectory: URL) {
        self.init(fileURL: DenialLedgerPaths(configDirectory: configDirectory).fileURL)
    }

    /// Best-effort post-decision audit write: lock, I/O, or encode failures
    /// drop the record silently. Enforcement is unaffected — the deny stands
    /// whether or not the audit row persists.
    public func append(_ record: DenialLedgerRecord, now: Date) {
        // Best-effort: the ledger is a post-decision audit record, not the enforcement path.
        let store = self.store
        let key = fileURL.path
        _ = try? store.withLock {
            do {
                try Self.appendLocked(record, now: now, store: store, key: key)
            } catch {
                Self.writeCache.set(nil, for: key)
                throw error
            }
        }
    }

    /// Returns denial records as of `now`, newest-first after cap.
    ///
    /// - Note: Reads the JSONL file (O(n) in file length). A missing file is empty.
    public func records(asOf now: Date) -> [DenialLedgerRecord] {
        pruned(store.load(), now: now).reversed()
    }

    /// Returns records still inside the age window, oldest first, capped at `RVHistory.maxRows`.
    public func pruned(_ records: [DenialLedgerRecord], now: Date) -> [DenialLedgerRecord] {
        Self.prunedIndices(records.map(\.timestamp), now: now).map { records[$0] }
    }

    /// Indices of `timestamps` that `pruned` keeps, in its order.
    private static func prunedIndices(_ timestamps: [Date], now: Date) -> [Int] {
        let cutoff = now.addingTimeInterval(-RVHistory.maxAge)
        let fresh = timestamps.indices
            .filter { timestamps[$0] >= cutoff }
            .sorted { timestamps[$0] < timestamps[$1] }
        if fresh.count <= RVHistory.maxRows {
            return fresh
        }
        return Array(fresh.suffix(RVHistory.maxRows))
    }

    private var store: FileLockedJSONLStore<DenialLedgerRecord> {
        let directory = fileURL.deletingLastPathComponent()
        return FileLockedJSONLStore(
            fileURL: fileURL,
            lockURL: DenialLedgerPaths(configDirectory: directory).lockURL,
            directoryURL: directory
        )
    }

    // MARK: - Append path

    /// What this process last wrote to a ledger file, keyed by the file's
    /// stamp. Every deny appended under the exclusive lock, and the old
    /// append decoded, pruned, re-encoded and renamed the whole file each
    /// time, so parallel denies queued behind each other. Another writer
    /// (an rv process evaluating without rvd) changes the stamp, so its rows
    /// are read, and the file rewritten, on the next append.
    struct WrittenFile {
        var stamp: FileStamp
        /// Exactly what `load` returns for the file, in file order: each row
        /// as read back from its line (dates keep whole seconds).
        var records: [DenialLedgerRecord]
        /// `lines[i]` is `records[i]` as saved.
        var lines: [String]
        /// Earliest timestamp in `records`; distant future when empty.
        var oldest: Date
    }

    /// Process-wide, since rvd builds a `DenialLedger` per deny.
    final class WriteCache: Sendable {
        private let files = Mutex<[String: WrittenFile]>([:])

        func get(_ key: String) -> WrittenFile? {
            files.withLock { $0[key] }
        }

        func set(_ file: WrittenFile?, for key: String) {
            files.withLock { $0[key] = file }
        }
    }

    static let writeCache = WriteCache()

    /// Caller holds the ledger lock.
    private static func appendLocked(
        _ record: DenialLedgerRecord,
        now: Date,
        store: FileLockedJSONLStore<DenialLedgerRecord>,
        key: String
    ) throws {
        let line = try FileLockedJSONLStore<DenialLedgerRecord>.encodeLine(record)
        let readBack = try FileLockedJSONLStore<DenialLedgerRecord>.decodeLine(line)
        let cutoff = now.addingTimeInterval(-RVHistory.maxAge)
        let cached = writeCache.get(key)
        let current = store.stamp()
        let fileIsOurs = current != nil && cached?.stamp == current
        if fileIsOurs, var file = cached,
           file.records.count < RVHistory.maxRows + compactionSlack,
           file.oldest >= cutoff, readBack.timestamp >= cutoff
        {
            // The file is exactly what this process last wrote, within the
            // cap's slack and the age window: append one line.
            writeCache.set(nil, for: key)
            try store.append(line: line)
            file.records.append(readBack)
            file.lines.append(line)
            file.oldest = min(file.oldest, readBack.timestamp)
            guard let stamp = store.stamp() else { return }
            file.stamp = stamp
            writeCache.set(file, for: key)
            return
        }
        // Rewrite: pruned to the cap and the age window. Lines this process
        // wrote are reused; rows another writer left are encoded again.
        var records: [DenialLedgerRecord]
        var lines: [String?]
        if fileIsOurs, let file = cached {
            records = file.records
            lines = file.lines
        } else {
            records = store.load()
            lines = Array(repeating: nil, count: records.count)
        }
        records.append(readBack)
        lines.append(line)
        let kept = prunedIndices(records.map(\.timestamp), now: now)
        let encoder = FileLockedJSONLStore<DenialLedgerRecord>.lineEncoder()
        var savedRecords: [DenialLedgerRecord] = []
        var savedLines: [String] = []
        savedRecords.reserveCapacity(kept.count)
        savedLines.reserveCapacity(kept.count)
        for index in kept {
            let line = try lines[index]
                ?? FileLockedJSONLStore<DenialLedgerRecord>.encodeLine(records[index], encoder: encoder)
            savedRecords.append(records[index])
            savedLines.append(line)
        }
        writeCache.set(nil, for: key)
        try store.save(lines: savedLines)
        guard let stamp = store.stamp() else { return }
        writeCache.set(
            WrittenFile(
                stamp: stamp,
                records: savedRecords,
                lines: savedLines,
                oldest: savedRecords.map(\.timestamp).min() ?? .distantFuture
            ),
            for: key
        )
    }
}
