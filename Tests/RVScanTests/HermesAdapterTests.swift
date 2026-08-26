import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

@Test func hermesAdapter_hostAndRoots() throws {
    let adapter = HermesStoreAdapter()
    #expect(adapter.host == .hermes)
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-hermes-home"))
    let roots = adapter.roots(home: home)
    #expect(roots.count == 1)
    #expect(roots[0].path.hasSuffix("/.hermes"))
}

@Test func hermesAdapter_extractsTerminalToolCall() throws {
    try withTempHome { homeURL in
        let store = homeURL.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let dbURL = store.appendingPathComponent("state.db")
        let toolCalls = try String(contentsOf: fixtureURL("hermes/terminal-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeHermesFixtureDatabase(at: dbURL, sessionID: "sess_fixture_1", toolCalls: toolCalls)

        let adapter = HermesStoreAdapter()
        #expect(adapter.recognizes(fileURL: dbURL))
        let data = try Data(contentsOf: dbURL)
        let events = try adapter.extract(fileURL: dbURL, data: data)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.allSatisfy { $0.host == .hermes })
        #expect(events.allSatisfy { $0.sessionID == "sess_fixture_1" })
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
}

@Test func hermesAdapter_extractsNestedFunctionTerminal() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("state.db")
        let toolCalls = try String(
            contentsOf: fixtureURL("hermes/nested-function-terminal.json"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try writeHermesFixtureDatabase(at: dbURL, sessionID: "sess_nested", toolCalls: toolCalls)
        let adapter = HermesStoreAdapter()
        let events = try adapter.extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.map(\.command.rawValue) == ["git status"])
        #expect(events.allSatisfy { $0.sessionID == "sess_nested" })
    }
}

@Test func hermesAdapter_recognizesOnlyStateDatabase() throws {
    let adapter = HermesStoreAdapter()
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/state.db")))
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/opencode.db")) == false)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/session.jsonl")) == false)
}

@Test func hermesAdapter_tempTreeOnly_notLiveHome() throws {
    try withTempHome { homeURL in
        let home = try #require(ScanHome(validating: homeURL.path))
        let adapter = HermesStoreAdapter()
        let root = try #require(adapter.roots(home: home).first)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        if let live = ProcessInfo.processInfo.environment["HOME"], live.isEmpty == false {
            #expect(root.path.hasPrefix(live) == false)
        }
    }
}

@Test func hermesAdapter_openOrPrepareFailureIsNotEmptySuccess() throws {
    try withTempHome { homeURL in
        let adapter = HermesStoreAdapter()
        let source = homeURL.appendingPathComponent("state.db")

        #expect(throws: HermesStoreError.unreadable(sourcePath: source.path)) {
            _ = try adapter.extract(fileURL: source, data: Data())
        }
        #expect(throws: HermesStoreError.unreadable(sourcePath: source.path)) {
            _ = try adapter.extract(fileURL: source, data: Data("not-a-database".utf8))
        }

        let noMessages = homeURL.appendingPathComponent("no-messages.db")
        try writeSQLiteDatabase(at: noMessages, sql: "CREATE TABLE other (id TEXT);")
        let noMessagesBytes = try Data(contentsOf: noMessages)
        #expect(throws: HermesStoreError.prepareFailed(sourcePath: noMessages.path)) {
            _ = try adapter.extract(fileURL: noMessages, data: noMessagesBytes)
        }

        let emptyMessages = homeURL.appendingPathComponent("empty-messages.db")
        try writeSQLiteDatabase(at: emptyMessages, sql: hermesMessagesDDL)
        let empty = try adapter.extract(
            fileURL: emptyMessages,
            data: Data(contentsOf: emptyMessages)
        )
        #expect(empty.isEmpty)
    }
}

@Test func hermesAdapter_walHeaderDatabaseExtractsTerminal() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("state.db")
        let toolCalls = try String(contentsOf: fixtureURL("hermes/terminal-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeHermesFixtureDatabase(at: dbURL, sessionID: "sess_wal", toolCalls: toolCalls)
        var data = try Data(contentsOf: dbURL)
        #expect(data.count > 19)
        data[18] = 2
        data[19] = 2
        let adapter = HermesStoreAdapter()
        let events = try adapter.extract(fileURL: dbURL, data: data)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.isEmpty == false)
    }
}

@Test func hermesAdapter_extractUsesProvidedDataNotPath() throws {
    try withTempHome { homeURL in
        let store = homeURL.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let dbURL = store.appendingPathComponent("state.db")
        let toolCalls = try String(contentsOf: fixtureURL("hermes/terminal-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeHermesFixtureDatabase(at: dbURL, sessionID: "sess_disk", toolCalls: toolCalls)
        let diskBytes = try Data(contentsOf: dbURL)

        let adapter = HermesStoreAdapter()
        #expect(throws: HermesStoreError.unreadable(sourcePath: dbURL.path)) {
            _ = try adapter.extract(fileURL: dbURL, data: Data("not-sqlite".utf8))
        }

        try FileManager.default.removeItem(at: dbURL)
        try Data("different-on-disk".utf8).write(to: dbURL)
        let events = try adapter.extract(fileURL: dbURL, data: diskBytes)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.allSatisfy { $0.host == .hermes })
        #expect(events.allSatisfy { $0.sessionID == "sess_disk" })
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
}

private enum HermesFixtureError: Error {
    case openFailed
    case execFailed
    case prepareFailed
    case insertFailed
}

private let hermesMessagesDDL = """
CREATE TABLE messages (
  session_id TEXT,
  role TEXT,
  content TEXT,
  tool_calls TEXT,
  timestamp REAL
);
"""

private func writeSQLiteDatabase(at url: URL, sql: String? = nil) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw HermesFixtureError.openFailed
    }
    defer { sqlite3_close(db) }
    if let sql {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HermesFixtureError.execFailed
        }
    }
}

private func writeHermesFixtureDatabase(at url: URL, sessionID: String, toolCalls: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw HermesFixtureError.openFailed
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, hermesMessagesDDL, nil, nil, nil) == SQLITE_OK else {
        throw HermesFixtureError.execFailed
    }

    var statement: OpaquePointer?
    let insert = "INSERT INTO messages (session_id, role, content, tool_calls, timestamp) VALUES (?, 'assistant', NULL, ?, 1710000000.0);"
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw HermesFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = sessionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    _ = toolCalls.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw HermesFixtureError.insertFailed
    }
}
