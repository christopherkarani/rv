import Foundation
import Testing
@testable import RVHistory

/// OPE-158 regression tests: locked read-modify-write in `DenialLedger.append`.
struct DenialLedgerConcurrencyTests {
    /// AC-001: concurrent appends lose no rows.
    @Test func concurrentAppends_loseNoRows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = DenialLedger(configDirectory: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let template = try decode(ConcurrencyJSONL.row)
        let taskCount = 8
        let appendsPerTask = 20
        let total = taskCount * appendsPerTask

        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<taskCount {
                group.addTask {
                    for rowIndex in 0..<appendsPerTask {
                        var record = template
                        record.timestamp = now.addingTimeInterval(
                            TimeInterval(taskIndex * appendsPerTask + rowIndex)
                        )
                        ledger.append(record, now: now.addingTimeInterval(TimeInterval(total)))
                    }
                }
            }
        }

        let rows = ledger.records(asOf: now.addingTimeInterval(TimeInterval(total)))
        #expect(rows.count == total)
    }

    /// AC-003: torn file (bad middle line, truncated last line) still loads decodable rows.
    @Test func tornFile_skipsBadLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-torn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("blocks.jsonl")
        let text = ConcurrencyJSONL.row + "\n"
            + "not-json-at-all\n"
            + ConcurrencyJSONL.row + "\n"
            + #"{"category":"core.git","host":"tty","path":""# // truncated, no trailing newline
        try Data(text.utf8).write(to: file)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = DenialLedger(fileURL: file).records(asOf: now)
        #expect(rows.count == 2)
    }

    private func decode(_ line: String) throws -> DenialLedgerRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DenialLedgerRecord.self, from: Data(line.utf8))
    }
}

private enum ConcurrencyJSONL {
    static let row =
        #"{"category":"core.git","host":"tty","path":"","rule_id":"core.git:reset-hard","timestamp":"2027-01-15T08:00:00Z","tool":"Bash"}"#
}
