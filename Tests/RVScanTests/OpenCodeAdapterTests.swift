import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

@Test func openCodeAdapter_hostAndRoots() throws {
    let adapter = OpenCodeStoreAdapter()
    #expect(adapter.host == .opencode)
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-opencode-home"))
    let roots = adapter.roots(home: home)
    #expect(roots.count == 1)
    #expect(roots[0].path.hasSuffix("/.local/share/opencode"))
}

@Test func openCodeAdapter_extractsBashPartCommand() throws {
    try withTempHome { homeURL in
        let store = homeURL.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let dbURL = store.appendingPathComponent("opencode.db")
        let partJSON = try String(contentsOf: fixtureURL("opencode/bash-part.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenCodeFixtureDatabase(at: dbURL, sessionID: "ses_fixture_1", partJSON: partJSON)

        let adapter = OpenCodeStoreAdapter()
        #expect(adapter.recognizes(fileURL: dbURL))
        let data = try Data(contentsOf: dbURL)
        let events = try adapter.extract(fileURL: dbURL, data: data)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.allSatisfy { $0.host == .opencode })
        #expect(events.allSatisfy { $0.sessionID == "ses_fixture_1" })
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
}

@Test func openCodeAdapter_recognizesOnlyDatabase() throws {
    let adapter = OpenCodeStoreAdapter()
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/opencode.db")))
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/chat_history.jsonl")) == false)
    #expect(adapter.recognizes(fileURL: URL(fileURLWithPath: "/x/session.jsonl")) == false)
}

@Test func openCodeAdapter_hostFilterIgnoresPiFixture() throws {
    let adapter = OpenCodeStoreAdapter()
    let pi = try fixtureURL("pi/session.jsonl")
    #expect(adapter.recognizes(fileURL: pi) == false)
}

@Test func openCodeAdapter_tempTreeOnly_notLiveHome() throws {
    try withTempHome { homeURL in
        let home = try #require(ScanHome(validating: homeURL.path))
        let adapter = OpenCodeStoreAdapter()
        let root = try #require(adapter.roots(home: home).first)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        if let live = ProcessInfo.processInfo.environment["HOME"], live.isEmpty == false {
            #expect(root.path.hasPrefix(live) == false)
        }
    }
}

@Test func openCodeAdapter_openOrPrepareFailureIsNotEmptySuccess() throws {
    try withTempHome { homeURL in
        let adapter = OpenCodeStoreAdapter()
        let source = homeURL.appendingPathComponent("opencode.db")

        #expect(throws: OpenCodeStoreError.unreadable(sourcePath: source.path)) {
            _ = try adapter.extract(fileURL: source, data: Data())
        }
        #expect(throws: OpenCodeStoreError.unreadable(sourcePath: source.path)) {
            _ = try adapter.extract(fileURL: source, data: Data("not-a-database".utf8))
        }

        let noPart = homeURL.appendingPathComponent("no-part.db")
        try writeSQLiteDatabase(at: noPart, sql: "CREATE TABLE other (id TEXT);")
        let noPartBytes = try Data(contentsOf: noPart)
        #expect(throws: OpenCodeStoreError.prepareFailed(sourcePath: noPart.path)) {
            _ = try adapter.extract(fileURL: noPart, data: noPartBytes)
        }

        let emptyPart = homeURL.appendingPathComponent("empty-part.db")
        try writeSQLiteDatabase(at: emptyPart, sql: openCodePartDDL)
        let empty = try adapter.extract(
            fileURL: emptyPart,
            data: Data(contentsOf: emptyPart)
        )
        #expect(empty.isEmpty)
    }
}

@Test func openCodeAdapter_walHeaderDatabaseExtractsBashPart() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("opencode.db")
        let partJSON = try String(contentsOf: fixtureURL("opencode/bash-part.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenCodeFixtureDatabase(at: dbURL, sessionID: "ses_wal", partJSON: partJSON)
        var data = try Data(contentsOf: dbURL)
        #expect(data.count > 19)
        data[18] = 2
        data[19] = 2
        let adapter = OpenCodeStoreAdapter()
        let events = try adapter.extract(fileURL: dbURL, data: data)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.isEmpty == false)
    }
}

@Test func openCodeAdapter_headerValidDeserializeFailureIsUnreadable() throws {
    try withTempHome { homeURL in
        let source = homeURL.appendingPathComponent("opencode.db")
        var image = Data("SQLite format 3\u{0}".utf8)
        image.append(Data(count: 512 - image.count))
        image[16] = 0
        image[17] = 0x03
        image[18] = 1
        image[19] = 1
        let adapter = OpenCodeStoreAdapter()
        #expect(throws: OpenCodeStoreError.unreadable(sourcePath: source.path)) {
            _ = try adapter.extract(fileURL: source, data: image)
        }
    }
}

@Test func openCodeAdapter_extractUsesProvidedDataNotPath() throws {
    try withTempHome { homeURL in
        let store = homeURL.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let dbURL = store.appendingPathComponent("opencode.db")
        let partJSON = try String(contentsOf: fixtureURL("opencode/bash-part.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenCodeFixtureDatabase(at: dbURL, sessionID: "ses_disk", partJSON: partJSON)
        let diskBytes = try Data(contentsOf: dbURL)

        let adapter = OpenCodeStoreAdapter()
        #expect(throws: OpenCodeStoreError.unreadable(sourcePath: dbURL.path)) {
            _ = try adapter.extract(fileURL: dbURL, data: Data("not-sqlite".utf8))
        }

        try FileManager.default.removeItem(at: dbURL)
        try Data("different-on-disk".utf8).write(to: dbURL)
        let events = try adapter.extract(fileURL: dbURL, data: diskBytes)
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
        #expect(events.allSatisfy { $0.host == .opencode })
        #expect(events.allSatisfy { $0.sessionID == "ses_disk" })
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
}

@Test func dayOneAdapters_hostIDsAreDistinct() {
    let hosts = [
        PiStoreAdapter().host,
        GrokStoreAdapter().host,
        OpenCodeStoreAdapter().host,
        OpenClawStoreAdapter().host,
        HermesStoreAdapter().host,
        CodexStoreAdapter().host,
    ]
    #expect(Set(hosts) == [.pi, .grok, .opencode, .openclaw, .hermes, .codex])
    #expect(hosts.contains(.claude) == false)
}

private enum OpenCodeFixtureError: Error {
    case openFailed
    case execFailed
    case prepareFailed
    case insertFailed
}

private let openCodePartDDL = """
CREATE TABLE part (
  id TEXT PRIMARY KEY,
  message_id TEXT,
  session_id TEXT,
  time_created INTEGER,
  time_updated INTEGER,
  data TEXT
);
"""

private func writeSQLiteDatabase(at url: URL, sql: String? = nil) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw OpenCodeFixtureError.openFailed
    }
    defer { sqlite3_close(db) }
    if let sql {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.execFailed
        }
    }
}

private func writeOpenCodeFixtureDatabase(at url: URL, sessionID: String, partJSON: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw OpenCodeFixtureError.openFailed
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, openCodePartDDL, nil, nil, nil) == SQLITE_OK else {
        throw OpenCodeFixtureError.execFailed
    }

    var statement: OpaquePointer?
    let insert = "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, 1, 1, ?);"
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw OpenCodeFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = "part_1".withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    _ = "msg_1".withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
    _ = sessionID.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
    _ = partJSON.withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw OpenCodeFixtureError.insertFailed
    }
}
