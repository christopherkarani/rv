import Foundation

/// JSONL denial store. Newest-first records. Prunes to 200 rows or 7 days.
public struct DenialLedger: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(configDirectory: URL) {
        self.init(fileURL: DenialLedgerPaths(configDirectory: configDirectory).fileURL)
    }

    public func append(_ record: DenialLedgerRecord, now: Date) {
        var records = loadRaw()
        records.append(record)
        write(pruned(records, now: now))
    }

    /// Returns denial records as of `now`, newest-first after cap.
    ///
    /// - Note: Reads the JSONL file (O(n) in file length). A missing file is empty.
    public func records(asOf now: Date) -> [DenialLedgerRecord] {
        pruned(loadRaw(), now: now).reversed()
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

    private func loadRaw() -> [DenialLedgerRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [DenialLedgerRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(DenialLedgerRecord.self, from: lineData)
            else {
                continue
            }
            records.append(record)
        }
        return records
    }

    private func write(_ records: [DenialLedgerRecord]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        for record in records {
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8)
            else {
                continue
            }
            lines.append(line)
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
