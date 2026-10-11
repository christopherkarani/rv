#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
@testable import RVFileStore

// MARK: - Helpers

private let ledgerNow = Date(timeIntervalSince1970: 1_800_000_000)

private func ledgerPrincipal() -> SecretsAuditPrincipal {
    SecretsAuditPrincipal(
        instanceID: AgentInstanceID(
            rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        ),
        definitionID: "claude",
        ownerUID: 501
    )
}

private func ledgerRecord(
    executionID: SecretsExecutionID = SecretsExecutionID(),
    timestamp: Date = ledgerNow,
    kind: SecretsAuditKind = .secretResolve,
    decision: SecretsAuditDecision = .resolved,
    cause: SecretsAuditCause? = nil
) -> SecretsAuditRecord {
    SecretsAuditRecord(
        executionID: executionID,
        timestamp: timestamp,
        principal: ledgerPrincipal(),
        kind: kind,
        addressOrRef: .secret(provider: "file", item: "api-token", field: nil),
        decision: decision,
        correlationID: SecretsCorrelationID(),
        cause: cause
    )
}

private func ledgerDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func encodeLine(_ record: SecretsAuditRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    return try #require(String(data: data, encoding: .utf8))
}

private func decodeLine(_ line: String) throws -> SecretsAuditRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(SecretsAuditRecord.self, from: Data(line.utf8))
}

private func ledgerPermissions(of url: URL) throws -> Int {
    let raw = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    return try #require(raw) & 0o777
}

// MARK: - Golden corpus: one type decodes every producer's rows

struct SecretsLedgerCorpusTests {
    /// The store's golden bytes decode through the single record type.
    @Test func golden_storeSecretResolveLineDecodes() throws {
        let golden =
            #"{"addressOrRef":{"item":"api-token","kind":"secret","provider":"file"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","principal":{"definitionID":"claude","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        let record = try decodeLine(golden)
        #expect(record.kind == .secretResolve)
        #expect(record.decision == .resolved)
        #expect(record.addressOrRef == .secret(provider: "file", item: "api-token", field: nil))
        #expect(record.cause == nil)
        #expect(try encodeLine(record) == golden)
    }

    /// Broker-shaped denied rows (provider-only cause, fielded ref) decode.
    @Test func golden_brokerDeniedLineDecodes() throws {
        let line =
            #"{"addressOrRef":{"field":"token","item":"api-token","kind":"secret","provider":"env"},"cause":"notFound:env","correlationId":"22222222-2222-2222-2222-222222222222","decision":"denied","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","principal":{"definitionID":"test-agent","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        let record = try decodeLine(line)
        #expect(record.kind == .secretResolve)
        #expect(record.decision == .denied)
        #expect(record.addressOrRef == .secret(provider: "env", item: "api-token", field: "token"))
        #expect(record.cause?.redacted == "notFound:env")
        #expect(try decodeLine(encodeLine(record)) == record)
    }

    /// Invoker-shaped tool rows decode to parsed addresses.
    @Test func golden_invokerToolRowDecodes() throws {
        let line =
            #"{"addressOrRef":{"address":"tools.demo.user.conn.read","kind":"tool"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"allowed","executionId":"11111111-1111-1111-1111-111111111111","kind":"tool.dispatch","principal":{"definitionID":"t8","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        let record = try decodeLine(line)
        #expect(record.kind == .toolDispatch)
        #expect(record.decision == .allowed)
        #expect(record.addressOrRef == .tool(try MCPToolAddress.parse("tools.demo.user.conn.read")))
        #expect(try decodeLine(encodeLine(record)) == record)
    }

    /// Invoker rows carrying raw attempted literals decode to the raw
    /// target instead of failing: the row stays visible to every reader.
    @Test(
        arguments: [
            "nope",
            "not a literal!",
            "tools.demo.user.conn.",
            String(repeating: "x", count: 200),
        ]
    )
    func golden_rawLiteralToolRowCarriesVerbatim(literal: String) throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "addressOrRef": ["address": literal, "kind": "tool"],
                "correlationId": "22222222-2222-2222-2222-222222222222",
                "decision": "denied",
                "executionId": "11111111-1111-1111-1111-111111111111",
                "kind": "tool.dispatch",
                "principal": [
                    "definitionID": "t8",
                    "instanceID": "33333333-3333-3333-3333-333333333333",
                    "ownerUID": 501,
                ],
                "timestamp": "2027-01-15T08:00:00Z",
            ]
        )
        let line = try #require(String(data: payload, encoding: .utf8))
        let record = try decodeLine(line)
        #expect(record.addressOrRef == .toolRaw(literal))
        let roundTripped = try decodeLine(encodeLine(record))
        #expect(roundTripped.addressOrRef == .toolRaw(literal))
        #expect(try encodeLine(record).contains(literal))
    }

    /// Unknown address kinds still fail the row (not the file): the line
    /// is skipped on read and preserved byte-for-byte by maintenance.
    @Test func golden_unknownAddressKindFailsTheRow() throws {
        let line =
            #"{"addressOrRef":{"kind":"host"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","principal":{"definitionID":"claude","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        #expect(throws: DecodingError.self) { try decodeLine(line) }
    }

    /// Malformed principals still fail the row.
    @Test func golden_malformedPrincipalFailsTheRow() throws {
        let line =
            #"{"addressOrRef":{"item":"api-token","kind":"secret","provider":"file"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.resolve","principal":{"definitionID":"claude","instanceID":"nope","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        #expect(throws: DecodingError.self) { try decodeLine(line) }
    }
}

// MARK: - Shared writer: hardening (migrated from the broker/invoker suites)

struct SecretsLedgerWriterTests {
    @Test func writer_emptyBatchCreatesNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-ledger-empty-\(UUID().uuidString)", isDirectory: true)
        try SecretsLedger.append([], directory: dir, retention: .default)
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test func writer_appendsDecodableLines() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-append")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = ledgerRecord()
        let second = ledgerRecord(kind: .toolOutcome, decision: .succeeded)
        try SecretsLedger.append([first, second], directory: dir, retention: .default)
        let text = try String(
            contentsOf: SecretsAuditPaths(configDirectory: dir).fileURL, encoding: .utf8
        )
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(try decodeLine(lines[0]) == first)
        #expect(try decodeLine(lines[1]) == second)
    }

    @Test func writer_setsOwnerOnlyPermissions() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-perms")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        let paths = SecretsAuditPaths(configDirectory: dir)
        #expect(try ledgerPermissions(of: paths.fileURL) == 0o600)
        #expect(try ledgerPermissions(of: dir) == 0o700)
        #expect(FileManager.default.fileExists(atPath: paths.lockURL.path))
        #expect(try ledgerPermissions(of: paths.lockURL) == 0o600)
    }

    @Test func writer_tightensLaxDirectory() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-tighten")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        #expect(try ledgerPermissions(of: dir) == 0o700)
    }

    @Test func writer_fileAsDirectoryDenies() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-filedir")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocker)
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: blocker, retention: .default)
        }
    }

    @Test func writer_symlinkedDirectoryDeniesWithoutTouchingTarget() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-dirlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = dir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: link, retention: .default)
        }
        #expect(try ledgerPermissions(of: target) == 0o755)
    }

    @Test func writer_symlinkedLedgerDeniesWithoutWritingTarget() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-ledgerlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real-ledger.jsonl", isDirectory: false)
        try "".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: SecretsAuditPaths(configDirectory: dir).fileURL, withDestinationURL: target
        )
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "")
    }

    @Test func writer_symlinkedLockDenies() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-locklink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.lock", isDirectory: false)
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: SecretsAuditPaths(configDirectory: dir).lockURL, withDestinationURL: target
        )
        #expect(throws: SecretsLedgerError.lockFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        }
    }

    @Test func writer_fifoLockDenies() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-lockfifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(mkfifo(SecretsAuditPaths(configDirectory: dir).lockURL.path, 0o600) == 0)
        #expect(throws: SecretsLedgerError.lockFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        }
    }

    @Test func writer_fifoLedgerDenies() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-ledgerfifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = SecretsAuditPaths(configDirectory: dir).fileURL
        #expect(mkfifo(ledger.path, 0o600) == 0)
        // Held reader so the O_WRONLY open succeeds instead of blocking;
        // the fstat type guard below it is what must deny.
        let reader = open(ledger.path, O_RDONLY | O_NONBLOCK)
        try #require(reader >= 0)
        defer { close(reader) }
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        }
    }

    @Test func writer_lockPathIsDirectoryDeniesWithLockFailed() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-lockdir")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: SecretsAuditPaths(configDirectory: dir).lockURL, withIntermediateDirectories: true
        )
        #expect(throws: SecretsLedgerError.lockFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        }
        #expect(SecretsLedger.loadRecords(fileURL: SecretsAuditPaths(configDirectory: dir).fileURL) == [])
    }
}

// MARK: - Shared writer: retention on the hot path

struct SecretsLedgerRetentionTests {
    @Test func writer_rotatesAutomaticallyWhenOverBudget() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-autorotate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let first = ledgerRecord(timestamp: ledgerNow)
        try SecretsLedger.append([first], directory: dir, retention: .default)
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: paths.fileURL.path)[.size] as? Int
        )
        let tight = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: size + 10, maxGenerations: 2
        )
        let second = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))
        try SecretsLedger.append([second], directory: dir, retention: tight)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path))
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [second])
        #expect(SecretsLedger.loadRecords(fileURL: paths.rotatedURL(generation: 1)) == [first])
    }

    @Test func writer_ledgerFullWhenRotationDisabled() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-full")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let first = ledgerRecord(timestamp: ledgerNow)
        try SecretsLedger.append([first], directory: dir, retention: .default)
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: paths.fileURL.path)[.size] as? Int
        )
        let tight = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: size + 10, maxGenerations: 0
        )
        #expect(throws: SecretsLedgerError.ledgerFull) {
            try SecretsLedger.append(
                [ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))],
                directory: dir,
                retention: tight
            )
        }
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [first])
    }

    @Test func writer_singleRowOverBudgetDeniesWithoutRotating() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-singlefull")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 200, maxGenerations: 3
        )
        #expect(throws: SecretsLedgerError.ledgerFull) {
            try SecretsLedger.append([ledgerRecord()], directory: dir, retention: retention)
        }
        #expect(SecretsLedger.loadRecords(
            fileURL: SecretsAuditPaths(configDirectory: dir).fileURL
        ) == [])
        #expect(FileManager.default.fileExists(
            atPath: SecretsAuditPaths(configDirectory: dir).rotatedURL(generation: 1).path
        ) == false)
    }

    @Test func writer_admissionGateExpiresBackdatedRows() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-gate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0
        )
        #expect(throws: SecretsLedgerError.rowExpired) {
            try SecretsLedger.append(
                [ledgerRecord(timestamp: ledgerNow.addingTimeInterval(-101))],
                directory: dir,
                retention: retention,
                admissionNow: ledgerNow
            )
        }
        #expect(SecretsLedger.loadRecords(
            fileURL: SecretsAuditPaths(configDirectory: dir).fileURL
        ) == [])
    }

    @Test func writer_hotPathWithoutGateAdmitsAnyTimestamp() throws {
        // Broker/invoker hot appends pass no admission clock: old
        // timestamps (fixed test fixtures, backdated producers) still
        // land. Only the store's admission gate throws rowExpired.
        let dir = try ledgerDir(prefix: "rv-ledger-nogate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0
        )
        let row = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(-10_000))
        try SecretsLedger.append([row], directory: dir, retention: retention)
        #expect(SecretsLedger.loadRecords(
            fileURL: SecretsAuditPaths(configDirectory: dir).fileURL
        ) == [row])
    }

    @Test func writer_admissionGateExpiresDisplacedRows() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-displaced")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(
            maxRows: 2, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 0
        )
        try SecretsLedger.append(
            [ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))],
            directory: dir, retention: retention, admissionNow: ledgerNow
        )
        try SecretsLedger.append(
            [ledgerRecord(timestamp: ledgerNow.addingTimeInterval(2))],
            directory: dir, retention: retention, admissionNow: ledgerNow
        )
        #expect(throws: SecretsLedgerError.rowExpired) {
            try SecretsLedger.append(
                [ledgerRecord(timestamp: ledgerNow)],
                directory: dir, retention: retention, admissionNow: ledgerNow
            )
        }
        #expect(SecretsLedger.loadRecords(
            fileURL: SecretsAuditPaths(configDirectory: dir).fileURL
        ).count == 2)
    }

    @Test func writer_deniedBackdatedAppendDoesNotRotate() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-denyrotate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 2
        )
        let oldest = ledgerRecord(timestamp: ledgerNow)
        let middle = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))
        let fresh = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(2))
        try SecretsLedger.append([oldest], directory: dir, retention: retention)
        #expect(try SecretsLedger.rotate(directory: dir, retention: retention) == true)
        try SecretsLedger.append([middle], directory: dir, retention: retention)
        #expect(try SecretsLedger.rotate(directory: dir, retention: retention) == true)
        try SecretsLedger.append([fresh], directory: dir, retention: retention)
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: paths.fileURL.path)[.size] as? Int
        )
        let tight = SecretsAuditRetention(
            maxRows: 100, maxAge: 100, maxBytes: size + 10, maxGenerations: 2
        )
        let backdated = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(-101))
        #expect(throws: SecretsLedgerError.rowExpired) {
            try SecretsLedger.append(
                [backdated],
                directory: dir,
                retention: tight,
                admissionNow: ledgerNow.addingTimeInterval(2)
            )
        }
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [fresh])
        #expect(SecretsLedger.loadRecords(fileURL: paths.rotatedURL(generation: 1)) == [middle])
        #expect(SecretsLedger.loadRecords(fileURL: paths.rotatedURL(generation: 2)) == [oldest])
    }

    @Test func writer_deniedOverCapBatchDoesNotRotate() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-denycap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let setup = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 2
        )
        let first = ledgerRecord(timestamp: ledgerNow)
        try SecretsLedger.append([first], directory: dir, retention: setup)
        let batch = [
            ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1)),
            ledgerRecord(timestamp: ledgerNow.addingTimeInterval(2)),
        ]
        var totalGrowth = 0
        for row in batch {
            totalGrowth += try encodeLine(row).utf8.count + 1
        }
        let tight = SecretsAuditRetention(
            maxRows: 1, maxAge: 1_000_000, maxBytes: totalGrowth + 10, maxGenerations: 2
        )
        #expect(throws: SecretsLedgerError.rowExpired) {
            try SecretsLedger.append(
                batch,
                directory: dir,
                retention: tight,
                admissionNow: ledgerNow.addingTimeInterval(2)
            )
        }
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [first])
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path) == false)
    }

    @Test func pruned_keepsNewestWithinWindow() throws {
        let retention = SecretsAuditRetention(
            maxRows: 3, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0
        )
        let stale = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(-10_000))
        var rows = [stale]
        for index in 0..<5 {
            rows.append(ledgerRecord(timestamp: ledgerNow.addingTimeInterval(TimeInterval(index))))
        }
        let kept = SecretsLedger.pruned(rows, now: ledgerNow.addingTimeInterval(5), retention: retention)
        #expect(kept.count == 3)
        #expect(kept.contains(stale) == false)
        #expect(kept.map(\.timestamp) == kept.map(\.timestamp).sorted())
    }
}

// MARK: - Maintenance preserves what it cannot decode

struct SecretsLedgerPreservationTests {
    @Test func maintenance_purgePreservesUndecodableBytes() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-preserve")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let keeper = ledgerRecord(timestamp: ledgerNow)
        let stale = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(-10_000))
        let unknownKind =
            #"{"addressOrRef":{"item":"x","kind":"secret","provider":"file"},"correlationId":"22222222-2222-2222-2222-222222222222","decision":"resolved","executionId":"11111111-1111-1111-1111-111111111111","kind":"secret.read","principal":{"definitionID":"c","instanceID":"33333333-3333-3333-3333-333333333333","ownerUID":501},"timestamp":"2027-01-15T08:00:00Z"}"#
        let torn = #"{"truncated": "#
        let invalidUTF8 = Data([0xFF, 0xFE])
        var bytes = Data()
        bytes += Data((try encodeLine(stale) + "\n").utf8)
        bytes += Data((try encodeLine(keeper) + "\n").utf8)
        bytes += Data((unknownKind + "\n").utf8)
        bytes += Data((torn + "\n").utf8)
        bytes += invalidUTF8 + Data([0x0A])
        bytes += Data("   \n".utf8)
        try bytes.write(to: paths.fileURL)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0
        )
        try SecretsLedger.purgeExpired(directory: dir, retention: retention, now: ledgerNow)
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [keeper])
        let after = try Data(contentsOf: paths.fileURL)
        #expect(after.range(of: Data(unknownKind.utf8)) != nil)
        #expect(after.range(of: Data(torn.utf8)) != nil)
        #expect(after.range(of: invalidUTF8) != nil)
        #expect(after.range(of: Data(try encodeLine(stale).utf8)) == nil)
    }

    @Test func maintenance_purgeToEmptyWritesEmptyFile() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-purgeempty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let stale = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(-10_000))
        try Data((try encodeLine(stale) + "\n").utf8).write(to: paths.fileURL)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0
        )
        try SecretsLedger.purgeExpired(directory: dir, retention: retention, now: ledgerNow)
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [])
        #expect((try Data(contentsOf: paths.fileURL)).isEmpty)
    }

    @Test func writer_appendAfterCorruptionPreservesBytes() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        try Data("not-json-at-all{{{".utf8).write(to: paths.fileURL)
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [])
        let row = ledgerRecord()
        try SecretsLedger.append([row], directory: dir, retention: .default)
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [row])
        let text = try String(contentsOf: paths.fileURL, encoding: .utf8)
        #expect(text.contains("not-json-at-all{{{"))
        // The torn tail is terminated, not fused: two segments, not one.
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func reads_matchFileLockedJSONLStoreOnHostileCorpus() throws {
        // The shared reader replaces FileLockedJSONLStore.load for this
        // record type: prove the decoded sets agree line for line.
        let dir = try ledgerDir(prefix: "rv-ledger-parity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let keeper = ledgerRecord()
        var bytes = Data()
        bytes += Data((try encodeLine(keeper) + "\n").utf8)
        bytes += Data("{\"truncated\": \n".utf8)
        bytes += Data([0xFF, 0xFE, 0x0A])
        bytes += Data("   \n".utf8)
        bytes += Data((try encodeLine(ledgerRecord()) + "\r\n").utf8)
        bytes += Data("  \n".utf8)
        try bytes.write(to: paths.fileURL)
        let legacy = FileLockedJSONLStore<SecretsAuditRecord>(
            fileURL: paths.fileURL,
            lockURL: paths.lockURL,
            directoryURL: dir
        ).load()
        let shared = SecretsLedger.loadRecords(fileURL: paths.fileURL)
        #expect(shared == legacy)
        #expect(shared.count == 2)
        #expect(shared.contains(keeper))
    }
}

// MARK: - Rotation keeps generation naming, perms, and lock discipline

struct SecretsLedgerRotationTests {
    @Test func rotate_movesHotToGenerationOne0600() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-rotate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let row = ledgerRecord()
        try SecretsLedger.append([row], directory: dir, retention: .default)
        #expect(try SecretsLedger.rotate(directory: dir, retention: .default) == true)
        #expect(FileManager.default.fileExists(atPath: paths.fileURL.path) == false)
        #expect(SecretsLedger.loadRecords(fileURL: paths.rotatedURL(generation: 1)) == [row])
        #expect(try ledgerPermissions(of: paths.rotatedURL(generation: 1)) == 0o600)
    }

    @Test func rotate_shiftsGenerationsAndDeletesBeyondCap() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-shift")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 2
        )
        let first = ledgerRecord(timestamp: ledgerNow)
        let second = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))
        let third = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(2))
        try SecretsLedger.append([first], directory: dir, retention: retention)
        #expect(try SecretsLedger.rotate(directory: dir, retention: retention) == true)
        try SecretsLedger.append([second], directory: dir, retention: retention)
        #expect(try SecretsLedger.rotate(directory: dir, retention: retention) == true)
        try SecretsLedger.append([third], directory: dir, retention: retention)
        #expect(try SecretsLedger.rotate(directory: dir, retention: retention) == true)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 3).path) == false)
        #expect(SecretsLedger.loadRecords(fileURL: paths.rotatedURL(generation: 1)) == [third])
        #expect(SecretsLedger.loadRecords(fileURL: paths.rotatedURL(generation: 2)) == [second])
    }

    @Test func rotate_skipsMissingMiddleGeneration() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-middle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        try SecretsLedger.append(
            [ledgerRecord(timestamp: ledgerNow)], directory: dir, retention: .default
        )
        #expect(try SecretsLedger.rotate(directory: dir, retention: .default) == true)
        try SecretsLedger.append(
            [ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))],
            directory: dir, retention: .default
        )
        #expect(try SecretsLedger.rotate(directory: dir, retention: .default) == true)
        try FileManager.default.removeItem(at: paths.rotatedURL(generation: 1))
        try SecretsLedger.append(
            [ledgerRecord(timestamp: ledgerNow.addingTimeInterval(2))],
            directory: dir, retention: .default
        )
        #expect(try SecretsLedger.rotate(directory: dir, retention: .default) == true)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path))
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 2).path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 3).path))
    }

    @Test func rotate_disabledReturnsFalseWithoutTouchingDisk() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-norotate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 0
        )
        let row = ledgerRecord()
        try SecretsLedger.append([row], directory: dir, retention: retention)
        #expect(try SecretsLedger.rotate(directory: dir, retention: retention) == false)
        #expect(SecretsLedger.loadRecords(
            fileURL: SecretsAuditPaths(configDirectory: dir).fileURL
        ) == [row])
        #expect(FileManager.default.fileExists(
            atPath: SecretsAuditPaths(configDirectory: dir).rotatedURL(generation: 1).path
        ) == false)
    }

    @Test func rotate_missingFileReturnsFalse() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try SecretsLedger.rotate(directory: dir, retention: .default) == false)
    }

    @Test func rotate_dirShapedOldestGenerationDeniesWithoutMovingHot() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-dirgen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 2
        )
        let row = ledgerRecord()
        try SecretsLedger.append([row], directory: dir, retention: retention)
        try FileManager.default.createDirectory(
            at: paths.rotatedURL(generation: 2), withIntermediateDirectories: true
        )
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.rotate(directory: dir, retention: retention)
        }
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [row])
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path) == false)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: paths.rotatedURL(generation: 2).path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test func paths_layoutMatchesLedgerConvention() {
        let root = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        let paths = SecretsAuditPaths(configDirectory: root)
        #expect(paths.fileURL.lastPathComponent == "secrets-audit.jsonl")
        #expect(paths.lockURL.lastPathComponent == "secrets-audit.lock")
        #expect(paths.tempURL.lastPathComponent == "secrets-audit.jsonl.tmp")
        #expect(paths.rotatedURL(generation: 1).lastPathComponent == "secrets-audit.1.jsonl")
        #expect(paths.rotatedURL(generation: 3).lastPathComponent == "secrets-audit.3.jsonl")
        let names = paths.uninstallArtifacts.map(\.lastPathComponent)
        #expect(names.contains("secrets-audit.jsonl"))
        #expect(names.contains("secrets-audit.lock"))
        #expect(names.contains("secrets-audit.jsonl.tmp"))
    }
}

// MARK: - Gap closure: audit-merge arms C1-C6

struct SecretsLedgerGapClosureTests {
    @Test func writer_batchTotalOverBudgetDeniesWithoutWriting() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-batchtotal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let first = ledgerRecord(timestamp: ledgerNow)
        try SecretsLedger.append([first], directory: dir, retention: .default)
        let second = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))
        let third = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(2))
        let size2 = try encodeLine(second).utf8.count + 1
        let size3 = try encodeLine(third).utf8.count + 1
        let total = size2 + size3
        let tight = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: total - 1, maxGenerations: 3
        )
        try #require(size2 <= tight.maxBytes && size3 <= tight.maxBytes)
        #expect(throws: SecretsLedgerError.ledgerFull) {
            try SecretsLedger.append([second, third], directory: dir, retention: tight)
        }
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [first])
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path) == false)
    }

    #if os(macOS)
    @Test func writer_immutableDirectoryDenies() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-uchgdir")
        defer {
            dir.path.withCString { _ = chflags($0, 0) }
            try? FileManager.default.removeItem(at: dir)
        }
        let setRC = dir.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
        try #require(setRC == 0)
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([ledgerRecord()], directory: dir, retention: .default)
        }
        #expect(SecretsLedger.loadRecords(
            fileURL: SecretsAuditPaths(configDirectory: dir).fileURL
        ) == [])
    }
    #endif

    @Test func rotate_directoryHotDeniesWithoutMoving() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-dirhot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        try FileManager.default.createDirectory(at: paths.fileURL, withIntermediateDirectories: false)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 2
        )
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.rotate(directory: dir, retention: retention)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.fileURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path) == false)
    }

    #if os(macOS)
    @Test func rotate_immutableGenerationDeniesShiftWithoutMovingHot() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-uchggen")
        defer {
            let gen1 = SecretsAuditPaths(configDirectory: dir).rotatedURL(generation: 1)
            gen1.path.withCString { _ = chflags($0, 0) }
            try? FileManager.default.removeItem(at: dir)
        }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 2
        )
        let first = ledgerRecord(timestamp: ledgerNow)
        let second = ledgerRecord(timestamp: ledgerNow.addingTimeInterval(1))
        try SecretsLedger.append([first], directory: dir, retention: retention)
        #expect(try SecretsLedger.rotate(directory: dir, retention: retention) == true)
        try SecretsLedger.append([second], directory: dir, retention: retention)
        let gen1 = paths.rotatedURL(generation: 1)
        let setRC = gen1.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
        try #require(setRC == 0)
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.rotate(directory: dir, retention: retention)
        }
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [second])
        #expect(SecretsLedger.loadRecords(fileURL: gen1) == [first])
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 2).path) == false)
    }
    #endif

    @Test func maintenance_purgeOntoDirectoryHotDeniesAndCleansTemp() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-purgedir")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SecretsAuditPaths(configDirectory: dir)
        try FileManager.default.createDirectory(at: paths.fileURL, withIntermediateDirectories: false)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 100, maxBytes: 1_000_000, maxGenerations: 0
        )
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.purgeExpired(directory: dir, retention: retention, now: ledgerNow)
        }
        #expect(FileManager.default.fileExists(atPath: paths.tempURL.path) == false)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.fileURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    #if os(macOS)
    @Test func rotate_immutableHotDeniesWithoutMoving() throws {
        let dir = try ledgerDir(prefix: "rv-ledger-uchghot")
        defer {
            let hot = SecretsAuditPaths(configDirectory: dir).fileURL
            hot.path.withCString { _ = chflags($0, 0) }
            try? FileManager.default.removeItem(at: dir)
        }
        let paths = SecretsAuditPaths(configDirectory: dir)
        let retention = SecretsAuditRetention(
            maxRows: 100, maxAge: 1_000_000, maxBytes: 1_000_000, maxGenerations: 2
        )
        let row = ledgerRecord()
        try SecretsLedger.append([row], directory: dir, retention: retention)
        let setRC = paths.fileURL.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
        try #require(setRC == 0)
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.rotate(directory: dir, retention: retention)
        }
        #expect(SecretsLedger.loadRecords(fileURL: paths.fileURL) == [row])
        #expect(FileManager.default.fileExists(atPath: paths.rotatedURL(generation: 1).path) == false)
    }
    #endif
}

// MARK: - Decision lifts and raw-literal factories

struct SecretsLedgerDecisionLiftTests {
    /// Every per-kind decision lifts to the same-named shared case. The
    /// approval arms are unreachable end-to-end (the invoker records
    /// `.canceled` waits as `.expired`), so this direct unit test is the
    /// only execution of the pendingApproval/canceled/timedOut/consumed
    /// mapping arms.
    @Test(
        arguments: [
            (ToolApprovalDecision.pendingApproval, SecretsAuditDecision.pendingApproval),
            (.approved, .approved),
            (.declined, .declined),
            (.expired, .expired),
            (.canceled, .canceled),
            (.timedOut, .timedOut),
            (.consumed, .consumed),
        ] as [(ToolApprovalDecision, SecretsAuditDecision)]
    )
    func approvalLift_mapsEveryCaseByName(perKind: ToolApprovalDecision, shared: SecretsAuditDecision) {
        #expect(SecretsAuditDecision(perKind) == shared)
        #expect(SecretsAuditDecision(perKind).rawValue == perKind.rawValue)
    }

    @Test(
        arguments: [
            (SecretResolveDecision.resolved, SecretsAuditDecision.resolved),
            (.denied, .denied),
        ] as [(SecretResolveDecision, SecretsAuditDecision)]
    )
    func resolveLift_mapsEveryCaseByName(perKind: SecretResolveDecision, shared: SecretsAuditDecision) {
        #expect(SecretsAuditDecision(perKind) == shared)
        #expect(SecretsAuditDecision(perKind).rawValue == perKind.rawValue)
    }

    @Test(
        arguments: [
            (ToolDispatchDecision.allowed, SecretsAuditDecision.allowed),
            (.pendingApproval, .pendingApproval),
            (.denied, .denied),
        ] as [(ToolDispatchDecision, SecretsAuditDecision)]
    )
    func dispatchLift_mapsEveryCaseByName(perKind: ToolDispatchDecision, shared: SecretsAuditDecision) {
        #expect(SecretsAuditDecision(perKind) == shared)
        #expect(SecretsAuditDecision(perKind).rawValue == perKind.rawValue)
    }

    @Test(
        arguments: [
            (ToolOutcomeDecision.succeeded, SecretsAuditDecision.succeeded),
            (.failed, .failed),
        ] as [(ToolOutcomeDecision, SecretsAuditDecision)]
    )
    func outcomeLift_mapsEveryCaseByName(perKind: ToolOutcomeDecision, shared: SecretsAuditDecision) {
        #expect(SecretsAuditDecision(perKind) == shared)
        #expect(SecretsAuditDecision(perKind).rawValue == perKind.rawValue)
    }

    /// The raw-literal overloads tag the matching kind, carry the literal
    /// verbatim as the raw target, and lift the per-kind decision.
    @Test func rawLiteralDispatch_carriesVerbatimTarget() {
        let record = SecretsAuditRecord.toolDispatch(
            executionID: SecretsExecutionID(),
            timestamp: ledgerNow,
            principal: ledgerPrincipal(),
            toolLiteral: "nope...(",
            decision: .denied,
            correlationID: SecretsCorrelationID()
        )
        #expect(record.kind == .toolDispatch)
        #expect(record.decision == .denied)
        #expect(record.addressOrRef == .toolRaw("nope...("))
    }

    @Test func rawLiteralApproval_carriesVerbatimTarget() {
        let record = SecretsAuditRecord.toolApproval(
            executionID: SecretsExecutionID(),
            timestamp: ledgerNow,
            principal: ledgerPrincipal(),
            toolLiteral: "nope...(",
            decision: .canceled,
            correlationID: SecretsCorrelationID()
        )
        #expect(record.kind == .toolApproval)
        #expect(record.decision == .canceled)
        #expect(record.addressOrRef == .toolRaw("nope...("))
    }

    @Test func rawLiteralOutcome_carriesVerbatimTarget() {
        let record = SecretsAuditRecord.toolOutcome(
            executionID: SecretsExecutionID(),
            timestamp: ledgerNow,
            principal: ledgerPrincipal(),
            toolLiteral: "nope...(",
            decision: .failed,
            correlationID: SecretsCorrelationID()
        )
        #expect(record.kind == .toolOutcome)
        #expect(record.decision == .failed)
        #expect(record.addressOrRef == .toolRaw("nope...("))
    }

    /// A literal that happens to parse still lands on the parsed target:
    /// the overloads share the record's tool-literal labeling.
    @Test func rawLiteralOverload_parsesCleanLiterals() throws {
        let literal = "tools.demo.user.conn.read"
        let record = SecretsAuditRecord.toolDispatch(
            executionID: SecretsExecutionID(),
            timestamp: ledgerNow,
            principal: ledgerPrincipal(),
            toolLiteral: literal,
            decision: .allowed,
            correlationID: SecretsCorrelationID()
        )
        #expect(record.addressOrRef == .tool(try MCPToolAddress.parse(literal)))
    }
}
