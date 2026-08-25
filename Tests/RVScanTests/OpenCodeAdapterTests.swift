import Foundation
import SQLite3
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
        let events = try adapter.extract(fileURL: dbURL, data: Data())
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

@Test func dayOneAdapters_hostIDsAreDistinct() {
    let hosts = [
        PiStoreAdapter().host,
        GrokStoreAdapter().host,
        OpenCodeStoreAdapter().host,
    ]
    #expect(Set(hosts) == [.pi, .grok, .opencode])
    #expect(hosts.contains(.claude) == false)
}

private func writeOpenCodeFixtureDatabase(at url: URL, sessionID: String, partJSON: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        Issue.record("failed to create fixture sqlite db")
        return
    }
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE part (
      id TEXT PRIMARY KEY,
      message_id TEXT,
      session_id TEXT,
      time_created INTEGER,
      time_updated INTEGER,
      data TEXT
    );
    """
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        Issue.record("failed to create part table")
        return
    }

    var statement: OpaquePointer?
    let insert = "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, 1, 1, ?);"
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        Issue.record("failed to prepare insert")
        return
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = "part_1".withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    _ = "msg_1".withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
    _ = sessionID.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
    _ = partJSON.withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        Issue.record("failed to insert part row")
        return
    }
}
