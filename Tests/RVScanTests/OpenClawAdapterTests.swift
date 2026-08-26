import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

@Test func openClawAdapter_hostAndRoots() throws {
    let adapter = OpenClawStoreAdapter()
    #expect(adapter.host == .openclaw)
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-openclaw-home"))
    let roots = adapter.roots(home: home)
    #expect(roots.count == 1)
    #expect(roots[0].path.hasSuffix("/.openclaw/agents"))
}

@Test func openClawAdapter_extractsExecToolCall() throws {
    try withTempHome { homeURL in
        let store = homeURL.appendingPathComponent(
            ".openclaw/agents/main/agent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let dbURL = store.appendingPathComponent("openclaw-agent.sqlite")
        let eventJSON = try String(contentsOf: fixtureURL("openclaw/exec-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenClawFixtureDatabase(at: dbURL, sessionID: "sess_fixture_1", eventJSON: eventJSON)

        let adapter = OpenClawStoreAdapter()
        #expect(adapter.recognizes(fileURL: dbURL))
        let data = try Data(contentsOf: dbURL)
        let events = try adapter.extract(fileURL: dbURL, data: data)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.allSatisfy { $0.host == .openclaw })
        #expect(events.allSatisfy { $0.sessionID == "sess_fixture_1" })
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
}

@Test func openClawAdapter_extractsNestedMessageExec() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("openclaw-agent.sqlite")
        let eventJSON = try String(
            contentsOf: fixtureURL("openclaw/nested-message-exec.json"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenClawFixtureDatabase(at: dbURL, sessionID: "sess_nested", eventJSON: eventJSON)
        let adapter = OpenClawStoreAdapter()
        let events = try adapter.extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.map(\.command.rawValue) == ["git status"])
        #expect(events.allSatisfy { $0.sessionID == "sess_nested" })
    }
}

@Test func openClawAdapter_recognizesOnlyAgentDatabase() throws {
    let adapter = OpenClawStoreAdapter()
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/openclaw-agent.sqlite")))
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/opencode.db")) == false)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/session.jsonl")) == false)
}

@Test func openClawAdapter_tempTreeOnly_notLiveHome() throws {
    try withTempHome { homeURL in
        let home = try #require(ScanHome(validating: homeURL.path))
        let adapter = OpenClawStoreAdapter()
        let root = try #require(adapter.roots(home: home).first)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        if let live = ProcessInfo.processInfo.environment["HOME"], live.isEmpty == false {
            #expect(root.path.hasPrefix(live) == false)
        }
    }
}

@Test func openClawAdapter_openOrPrepareFailureIsNotEmptySuccess() throws {
    try withTempHome { homeURL in
        let adapter = OpenClawStoreAdapter()
        let source = homeURL.appendingPathComponent("openclaw-agent.sqlite")

        #expect(throws: OpenClawStoreError.unreadable(sourcePath: source.path)) {
            _ = try adapter.extract(fileURL: source, data: Data())
        }
        #expect(throws: OpenClawStoreError.unreadable(sourcePath: source.path)) {
            _ = try adapter.extract(fileURL: source, data: Data("not-a-database".utf8))
        }

        let noEvents = homeURL.appendingPathComponent("no-events.db")
        try writeSQLiteDatabase(at: noEvents, sql: "CREATE TABLE other (id TEXT);")
        let noEventsBytes = try Data(contentsOf: noEvents)
        #expect(throws: OpenClawStoreError.prepareFailed(sourcePath: noEvents.path)) {
            _ = try adapter.extract(fileURL: noEvents, data: noEventsBytes)
        }

        let emptyEvents = homeURL.appendingPathComponent("empty-events.db")
        try writeSQLiteDatabase(at: emptyEvents, sql: openClawTranscriptDDL)
        let empty = try adapter.extract(
            fileURL: emptyEvents,
            data: Data(contentsOf: emptyEvents)
        )
        #expect(empty.isEmpty)
    }
}

@Test func openClawAdapter_walHeaderDatabaseExtractsExec() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("openclaw-agent.sqlite")
        let eventJSON = try String(contentsOf: fixtureURL("openclaw/exec-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenClawFixtureDatabase(at: dbURL, sessionID: "sess_wal", eventJSON: eventJSON)
        var data = try Data(contentsOf: dbURL)
        #expect(data.count > 19)
        data[18] = 2
        data[19] = 2
        let adapter = OpenClawStoreAdapter()
        let events = try adapter.extract(fileURL: dbURL, data: data)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.isEmpty == false)
    }
}

@Test func openClawAdapter_extractUsesProvidedDataNotPath() throws {
    try withTempHome { homeURL in
        let store = homeURL.appendingPathComponent(
            ".openclaw/agents/main/agent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let dbURL = store.appendingPathComponent("openclaw-agent.sqlite")
        let eventJSON = try String(contentsOf: fixtureURL("openclaw/exec-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenClawFixtureDatabase(at: dbURL, sessionID: "sess_disk", eventJSON: eventJSON)
        let diskBytes = try Data(contentsOf: dbURL)

        let adapter = OpenClawStoreAdapter()
        #expect(throws: OpenClawStoreError.unreadable(sourcePath: dbURL.path)) {
            _ = try adapter.extract(fileURL: dbURL, data: Data("not-sqlite".utf8))
        }

        try FileManager.default.removeItem(at: dbURL)
        try Data("different-on-disk".utf8).write(to: dbURL)
        let events = try adapter.extract(fileURL: dbURL, data: diskBytes)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.allSatisfy { $0.host == .openclaw })
        #expect(events.allSatisfy { $0.sessionID == "sess_disk" })
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
}

private enum OpenClawFixtureError: Error {
    case openFailed
    case execFailed
    case prepareFailed
    case insertFailed
}

private let openClawTranscriptDDL = """
CREATE TABLE transcript_events (
  session_id TEXT,
  seq INTEGER,
  event_json TEXT,
  created_at INTEGER
);
"""

private func writeSQLiteDatabase(at url: URL, sql: String? = nil) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw OpenClawFixtureError.openFailed
    }
    defer { sqlite3_close(db) }
    if let sql {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenClawFixtureError.execFailed
        }
    }
}

private func writeOpenClawFixtureDatabase(at url: URL, sessionID: String, eventJSON: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw OpenClawFixtureError.openFailed
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, openClawTranscriptDDL, nil, nil, nil) == SQLITE_OK else {
        throw OpenClawFixtureError.execFailed
    }

    var statement: OpaquePointer?
    let insert = "INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, 1, ?, 1);"
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw OpenClawFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = sessionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    _ = eventJSON.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw OpenClawFixtureError.insertFailed
    }
}
