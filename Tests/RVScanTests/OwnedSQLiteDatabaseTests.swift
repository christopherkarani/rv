import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import RVScan

@Test func ownedSQLiteDatabase_readsDeserializedImageInsideConnectionBorrow() throws {
    try withTempHome { homeURL in
        let databaseURL = homeURL.appendingPathComponent("numbers.db")
        try writeSQLiteDatabase(
            at: databaseURL,
            sql: "CREATE TABLE numbers (value INTEGER); INSERT INTO numbers VALUES (42);"
        )
        let image = try Data(contentsOf: databaseURL)
        let opened = try makeOwnedSQLiteDatabase(from: image)

        let value = try opened.withConnection { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM numbers;", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                throw OwnedSQLiteDatabaseTestError.prepareFailed
            }
            defer { _ = sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw OwnedSQLiteDatabaseTestError.stepFailed
            }
            let value = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw OwnedSQLiteDatabaseTestError.stepFailed
            }
            return value
        }

        #expect(value == 42)
    }
}

@Test func ownedSQLiteDatabase_drainsAbandonedStatementBeforeNextExtraction() throws {
    try withTempHome { homeURL in
        let databaseURL = homeURL.appendingPathComponent("numbers.db")
        try writeSQLiteDatabase(
            at: databaseURL,
            sql: "CREATE TABLE numbers (value INTEGER); INSERT INTO numbers VALUES (42);"
        )
        let image = try Data(contentsOf: databaseURL)

        do {
            let opened = try makeOwnedSQLiteDatabase(from: image)
            try opened.withConnection { db in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT value FROM numbers;", -1, &statement, nil) == SQLITE_OK,
                      statement != nil
                else {
                    throw OwnedSQLiteDatabaseTestError.prepareFailed
                }
                // Deliberately leave this statement unfinalized. The owner
                // must drain it before freeing the deserialized image.
            }
        }

        let openCodeURL = homeURL.appendingPathComponent("opencode.db")
        let partJSON = try String(
            contentsOf: fixtureURL("opencode/bash-part.json"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try writeOpenCodeFixtureDatabase(
            at: openCodeURL,
            sessionID: "ses_owned_sqlite",
            partJSON: partJSON
        )

        let events = try OpenCodeStoreAdapter().extract(
            fileURL: openCodeURL,
            data: Data(contentsOf: openCodeURL)
        )
        #expect(events.map(\.command.rawValue) == ["git reset --hard"])
    }
}

private enum OwnedSQLiteDatabaseTestError: Error {
    case openFailed
    case allocationFailed
    case copyFailed
    case deserializeFailed
    case execFailed
    case prepareFailed
    case stepFailed
    case insertFailed
}

private func makeOwnedSQLiteDatabase(from data: Data) throws -> OwnedSQLiteDatabase {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
        if let db { _ = sqlite3_close(db) }
        throw OwnedSQLiteDatabaseTestError.openFailed
    }

    let byteCount = data.count
    guard let raw = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
        _ = sqlite3_close(db)
        throw OwnedSQLiteDatabaseTestError.allocationFailed
    }

    let copied = data.withUnsafeBytes { bytes -> Bool in
        guard let base = bytes.baseAddress else { return false }
        raw.copyMemory(from: base, byteCount: byteCount)
        return true
    }
    guard copied else {
        sqlite3_free(raw)
        _ = sqlite3_close(db)
        throw OwnedSQLiteDatabaseTestError.copyFailed
    }

    let flags = UInt32(bitPattern: SQLITE_DESERIALIZE_READONLY)
    let status = sqlite3_deserialize(
        db,
        "main",
        raw.assumingMemoryBound(to: UInt8.self),
        sqlite3_int64(byteCount),
        sqlite3_int64(byteCount),
        flags
    )
    guard status == SQLITE_OK else {
        sqlite3_free(raw)
        _ = sqlite3_close(db)
        throw OwnedSQLiteDatabaseTestError.deserializeFailed
    }
    return OwnedSQLiteDatabase(db: db, buffer: raw)
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

private func writeSQLiteDatabase(at url: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        if let db { _ = sqlite3_close(db) }
        throw OwnedSQLiteDatabaseTestError.openFailed
    }
    defer { _ = sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw OwnedSQLiteDatabaseTestError.execFailed
    }
}

private func writeOpenCodeFixtureDatabase(
    at url: URL,
    sessionID: String,
    partJSON: String
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        if let db { _ = sqlite3_close(db) }
        throw OwnedSQLiteDatabaseTestError.openFailed
    }
    defer { _ = sqlite3_close(db) }

    guard sqlite3_exec(db, openCodePartDDL, nil, nil, nil) == SQLITE_OK else {
        throw OwnedSQLiteDatabaseTestError.execFailed
    }

    var statement: OpaquePointer?
    let insert = "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, 1, 1, ?);"
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
        throw OwnedSQLiteDatabaseTestError.prepareFailed
    }
    defer { _ = sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = "part_1".withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    _ = "msg_1".withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
    _ = sessionID.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
    _ = partJSON.withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw OwnedSQLiteDatabaseTestError.insertFailed
    }
}
