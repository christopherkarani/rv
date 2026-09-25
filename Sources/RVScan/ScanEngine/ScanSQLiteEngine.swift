#if canImport(SQLite3)
import SQLite3
#endif
import Foundation

/// Deserialized-SQLite reads shared by the Hermes, OpenClaw, and OpenCode
/// adapters: header gate, WAL-patched readonly deserialize, prepare/step
/// loop, and fail-closed error mapping.
enum ScanSQLiteEngine {
    static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    /// Run `sql` over deserialized `data`, visiting each result row.
    /// A missing table (or any other prepare failure on a valid image) throws
    /// `prepareFailed`; corrupt images and short reads throw `unreadable`.
    static func rows(
        in data: Data,
        sourcePath: String,
        sql: String,
        visit: (OpaquePointer) -> Void
    ) throws {
        let opened = try deserializedDatabase(from: data, sourcePath: sourcePath)

        // Keep SQLite statement use inside the borrow; the owner stays alive
        // until this closure finalizes every statement and returns.
        try opened.withConnection { db in
            var statement: OpaquePointer?
            let prepareStatus = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard prepareStatus == SQLITE_OK, let statement else {
                if statement != nil { _ = sqlite3_finalize(statement) }
                switch prepareStatus {
                case SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_CANTOPEN:
                    throw ScanStoreError.unreadable(sourcePath: sourcePath)
                default:
                    throw ScanStoreError.prepareFailed(sourcePath: sourcePath)
                }
            }
            defer { _ = sqlite3_finalize(statement) }

            var stepStatus = sqlite3_step(statement)
            while stepStatus == SQLITE_ROW {
                visit(statement)
                stepStatus = sqlite3_step(statement)
            }
            guard stepStatus == SQLITE_DONE else {
                throw ScanStoreError.unreadable(sourcePath: sourcePath)
            }
        }
    }

    static func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func deserializedDatabase(
        from data: Data,
        sourcePath: String
    ) throws -> OwnedSQLiteDatabase {
        guard data.starts(with: sqliteHeader) else {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }

        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            if let db { _ = sqlite3_close(db) }
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }

        let byteCount = data.count
        guard let raw = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            _ = sqlite3_close(db)
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }

        let copied = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            raw.copyMemory(from: base, byteCount: byteCount)
            return true
        }
        guard copied else {
            sqlite3_free(raw)
            _ = sqlite3_close(db)
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }

        // WAL stores write/read format 2 at header bytes 18–19. Deserialize
        // has no WAL sidecar, so those bytes must be 1 (rollback) or use
        // fails with SQLITE_CANTOPEN.
        if byteCount > 19 {
            let header = raw.assumingMemoryBound(to: UInt8.self)
            header[18] = 1
            header[19] = 1
        }

        // `withConnection` keeps the owner alive while statements use the
        // deserialized image. Its deinit drains BUSY statements and frees P
        // only after close succeeds. Do not set FREEONCLOSE — SQLite frees P
        // itself on deserialize failure when that bit is set, which would
        // double-free if we also free it.
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
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }
        return OwnedSQLiteDatabase(db: db, buffer: raw)
    }
}
