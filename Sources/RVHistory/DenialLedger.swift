import Foundation
import RVFileStore

/// JSONL denial store. Newest-first records. Prunes to 200 rows or 7 days.
public struct DenialLedger: Sendable {
    public var fileURL: URL

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
        _ = try? store.withLock {
            var records = store.load()
            records.append(record)
            try store.save(pruned(records, now: now))
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
        let cutoff = now.addingTimeInterval(-RVHistory.maxAge)
        let fresh = records
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
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
}
