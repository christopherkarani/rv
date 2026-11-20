import Foundation
import Testing
import RVDomain
import RVFileStore
@testable import RVHistory

/// rvd appends a denial row on every deny under `blocks.lock`. The old
/// append loaded, pruned, re-encoded and renamed the whole 200-row file each
/// time, so parallel denies queued behind each other. An append now writes
/// one line while the file is what this process last wrote; the file is
/// rewritten only to prune (past the cap's slack or the age window) or after
/// another writer changed it. Reads keep their contract: newest first, at
/// most 200 rows, none older than 7 days.
struct DenialLedgerScalingTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func row(_ index: Int, at time: Date? = nil) throws -> DenialLedgerRecord {
        DenialLedgerRecord(
            timestamp: time ?? now.addingTimeInterval(TimeInterval(index)),
            host: .hook(.claude),
            tool: .bash,
            ruleID: try #require(RuleID(rawValue: "core.git:reset-hard")),
            category: .pack(.coreGit),
            path: "/tmp/rv/\(index)",
            session: "s-\(index)"
        )
    }

    private static func inode(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attrs[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    /// Counts the times the ledger file is replaced. Holds the current file
    /// open so its inode cannot be reused by the next one.
    private final class ReplacementCounter {
        private var held: FileHandle
        private var heldInode: UInt64
        private(set) var replacements = 0
        let url: URL

        init(_ url: URL) throws {
            self.url = url
            held = try FileHandle(forReadingFrom: url)
            heldInode = try DenialLedgerScalingTests.inode(url)
        }

        func check() throws {
            let current = try DenialLedgerScalingTests.inode(url)
            guard current != heldInode else { return }
            replacements += 1
            try held.close()
            held = try FileHandle(forReadingFrom: url)
            heldInode = current
        }
    }

    private static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func anAppendWritesOneLineInPlace() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DenialLedger(configDirectory: root)
        for index in 0..<100 {
            ledger.append(try Self.row(index), now: Self.now.addingTimeInterval(TimeInterval(index)))
        }
        let counter = try ReplacementCounter(ledger.fileURL)
        let linesBefore = try Self.lines(ledger.fileURL)
        for index in 100..<110 {
            ledger.append(try Self.row(index), now: Self.now.addingTimeInterval(TimeInterval(index)))
            try counter.check()
        }
        // The old append renamed a fresh file into place every time.
        #expect(counter.replacements == 0)
        let linesAfter = try Self.lines(ledger.fileURL)
        #expect(linesAfter.count == 110)
        #expect(Array(linesAfter.prefix(100)) == linesBefore)
    }

    /// Past the cap the file grows by up to `compactionSlack` rows, then one
    /// rewrite prunes it to the cap. Reads never see more than the cap.
    @Test func pruningAtTheCapIsAmortized() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DenialLedger(configDirectory: root)
        let total = RVHistory.maxRows + 3 * DenialLedger.compactionSlack + 7
        ledger.append(try Self.row(0), now: Self.now)
        let counter = try ReplacementCounter(ledger.fileURL)
        var largest = 1
        for index in 1..<total {
            let at = Self.now.addingTimeInterval(TimeInterval(index))
            ledger.append(try Self.row(index), now: at)
            try counter.check()
            largest = max(largest, try Self.lines(ledger.fileURL).count)
            let read = ledger.records(asOf: at)
            #expect(read.count == min(index + 1, RVHistory.maxRows))
            #expect(read.first?.path == "/tmp/rv/\(index)")
        }
        #expect(largest == RVHistory.maxRows + DenialLedger.compactionSlack)
        // One rewrite per slack's worth of rows past the cap; the old append
        // rewrote the file on every one.
        #expect(counter.replacements == (total - RVHistory.maxRows - 1) / DenialLedger.compactionSlack,
                "\(counter.replacements) rewrites for \(total) appends")
        let read = ledger.records(asOf: Self.now.addingTimeInterval(TimeInterval(total)))
        #expect(read.map(\.path) == (total - RVHistory.maxRows..<total).reversed().map { "/tmp/rv/\($0)" })
    }

    /// The age window is not amortized: a row past 7 days is gone from the
    /// file after the next append, not only hidden from reads.
    @Test func rowsPastTheAgeWindowLeaveTheFileOnTheNextAppend() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DenialLedger(configDirectory: root)
        ledger.append(try Self.row(0), now: Self.now)
        ledger.append(try Self.row(1), now: Self.now.addingTimeInterval(1))
        let later = Self.now.addingTimeInterval(RVHistory.maxAge + 0.5)
        ledger.append(try Self.row(2, at: later), now: later)
        let text = try Self.lines(ledger.fileURL)
        #expect(text.count == 2)
        #expect(text.contains { $0.contains("/tmp/rv/0") } == false)
        #expect(ledger.records(asOf: later).map(\.path) == ["/tmp/rv/2", "/tmp/rv/1"])
    }

    /// Another process's rewrite (an rv evaluating without rvd) or append is
    /// read before the next append and kept.
    @Test func anotherWritersRowsAreKept() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DenialLedger(configDirectory: root)
        for index in 0..<3 {
            ledger.append(try Self.row(index), now: Self.now)
        }
        // Another process rewrites the file under the lock, adding a row.
        let other = FileLockedJSONLStore<DenialLedgerRecord>(
            fileURL: ledger.fileURL,
            lockURL: DenialLedgerPaths(configDirectory: root).lockURL,
            directoryURL: root
        )
        try other.withLock {
            try other.save(other.load() + [try Self.row(10)])
        }
        ledger.append(try Self.row(4), now: Self.now)
        // Another process appends a line in place.
        let line = try FileLockedJSONLStore<DenialLedgerRecord>.encodeLine(try Self.row(11))
        try other.withLock { try other.append(line: line) }
        ledger.append(try Self.row(5), now: Self.now)
        let paths = Set(ledger.records(asOf: Self.now.addingTimeInterval(20)).map(\.path))
        #expect(paths == Set([0, 1, 2, 4, 5, 10, 11].map { "/tmp/rv/\($0)" }))
        #expect(try Self.lines(ledger.fileURL).count == 7)
    }

    /// The same, with this process and an old-style writer racing: every
    /// row from both lands.
    @Test func concurrentForeignRewritesLoseNoRows() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DenialLedger(configDirectory: root)
        let other = FileLockedJSONLStore<DenialLedgerRecord>(
            fileURL: ledger.fileURL,
            lockURL: DenialLedgerPaths(configDirectory: root).lockURL,
            directoryURL: root
        )
        let perTask = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<4 {
                group.addTask {
                    for step in 0..<perTask {
                        let index = task * perTask + step
                        if task == 0 {
                            let row = try Self.row(index)
                            try other.withLock { try other.save(other.load() + [row]) }
                        } else {
                            ledger.append(try Self.row(index), now: Self.now)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        let read = ledger.records(asOf: Self.now.addingTimeInterval(TimeInterval(4 * perTask)))
        #expect(read.count == 4 * perTask)
    }

    /// After reading a file another writer left, the next write is a full
    /// rewrite: a torn last line is dropped, never appended after.
    @Test func aTornLineIsRewrittenAwayNotAppendedAfter() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DenialLedger(configDirectory: root)
        let whole = try FileLockedJSONLStore<DenialLedgerRecord>.encodeLine(try Self.row(0))
        try Data((whole + "\n" + #"{"category":"core.git","host":"tty""#).utf8).write(to: ledger.fileURL)
        ledger.append(try Self.row(1), now: Self.now)
        ledger.append(try Self.row(2), now: Self.now)
        let text = try Self.lines(ledger.fileURL)
        #expect(text.count == 3)
        #expect(text.first == whole)
        #expect(ledger.records(asOf: Self.now.addingTimeInterval(5)).count == 3)
    }

    /// Mean wall time of `count` appends to a ledger already holding `rows`.
    private func meanAppend(seeded rows: Int, count: Int) throws -> Duration {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DenialLedger(configDirectory: root)
        for index in 0..<rows {
            ledger.append(try Self.row(index), now: Self.now)
        }
        let started = ContinuousClock.now
        for index in rows..<(rows + count) {
            ledger.append(try Self.row(index), now: Self.now)
        }
        return (ContinuousClock.now - started) / count
    }

    @Test func appendCostDoesNotScaleWithLedgerSize() throws {
        let small = try meanAppend(seeded: 5, count: 20)
        let large = try meanAppend(seeded: 180, count: 20)
        print("denial append mean: 5 rows \(small), 180 rows \(large)")
        // Before, a 180-row append decoded and re-encoded every row. Generous
        // for a shared CI host.
        #expect(large < small * 4 + .milliseconds(2), "180-row append \(large) vs 5-row \(small)")
    }
}
