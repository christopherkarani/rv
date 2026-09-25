import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

/// T4: closed scan/extract errors (`SessionStoreError`, `.extractFailed`).
@Test func scanError_signaturesAreClosed() {
    // Compile-time proof: these bindings only type-check when `extract` and
    // `run` declare the closed `throws(...)` types (REQ-003).
    let _: (URL, Data) throws(SessionStoreError) -> [ExtractedEvent] =
        CursorStoreAdapter().extract
    let _: (SessionScanRequest, FileManager) throws(SessionScanError) -> SessionScanResult =
        SessionScan().run
}

@Test func scanError_cursorUnreadableIsClosed() throws {
    let adapter = CursorStoreAdapter()
    let source = URL(fileURLWithPath: "/tmp/rv-scan-errors/cursor.jsonl")
    #expect(throws: SessionStoreError.unreadable(host: .cursor, sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data())
    }
}

@Test func scanError_openClawMissingTableIsQueryFailed() throws {
    try withScanErrorTempDir { dir in
        let db = dir.appendingPathComponent("openclaw-agent.sqlite")
        try writeScanErrorDatabase(at: db, sql: "CREATE TABLE other (id TEXT);")
        let adapter = OpenClawStoreAdapter()
        #expect(throws: SessionStoreError.queryFailed(host: .openclaw, sourcePath: db.path)) {
            _ = try adapter.extract(fileURL: db, data: Data(contentsOf: db))
        }
    }
}

@Test func scanError_runWrapsRecognizedExtractFailure() throws {
    try withScanErrorTempDir { root in
        let db = root.appendingPathComponent("opencode.db")
        try Data().write(to: db, options: .atomic)
        let home = try #require(ScanHome(validating: "/tmp/rv-scan-unused-home"))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let expected = db.standardizedFileURL.path
        #expect(
            throws: SessionScanError.extractFailed(
                .unreadable(host: .opencode, sourcePath: expected)
            )
        ) {
            try SessionScan().run(
                SessionScanRequest(home: home, now: now, rootPath: root.path, timeWindow: .all)
            )
        }
    }
}

@Test func scanError_runWrapsQueryFailure() throws {
    try withScanErrorTempDir { root in
        let db = root.appendingPathComponent("openclaw-agent.sqlite")
        try writeScanErrorDatabase(at: db, sql: "CREATE TABLE other (id TEXT);")
        let home = try #require(ScanHome(validating: "/tmp/rv-scan-unused-home"))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let expected = db.standardizedFileURL.path
        #expect(
            throws: SessionScanError.extractFailed(
                .queryFailed(host: .openclaw, sourcePath: expected)
            )
        ) {
            try SessionScan().run(
                SessionScanRequest(home: home, now: now, rootPath: root.path, timeWindow: .all)
            )
        }
    }
}

@Test func scanError_globOnlyExtractFailureSkips() throws {
    try withScanErrorTempDir { root in
        // Unrecognized by every adapter; garbage bytes make the fail-closed
        // adapters throw, which the glob-only rule must skip, not abort on.
        try Data("not-json\n".utf8).write(
            to: root.appendingPathComponent("notes.txt"),
            options: .atomic
        )
        let home = try #require(ScanHome(validating: "/tmp/rv-scan-unused-home"))
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let result = try SessionScan().run(
            SessionScanRequest(
                home: home,
                now: now,
                rootPath: root.path,
                includeGlobs: ["*.txt"],
                timeWindow: .all
            )
        )
        #expect(result.report.findings.isEmpty)
        #expect(result.report.eventsExtracted == 0)
    }
}

private func withScanErrorTempDir(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-scan-errors-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private enum ScanErrorFixtureError: Error {
    case openFailed
    case execFailed
}

private func writeScanErrorDatabase(at url: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw ScanErrorFixtureError.openFailed
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw ScanErrorFixtureError.execFailed
    }
}
