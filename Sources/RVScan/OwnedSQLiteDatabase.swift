#if canImport(SQLite3)
import SQLite3
#endif

/// A deserialized SQLite handle and its backing allocation with one owner.
/// `withConnection` keeps the owner alive for the full statement lifetime.
struct OwnedSQLiteDatabase: ~Copyable {
    private let db: OpaquePointer
    private let buffer: UnsafeMutableRawPointer

    init(db: OpaquePointer, buffer: UnsafeMutableRawPointer) {
        self.db = db
        self.buffer = buffer
    }

    borrowing func withConnection<Result>(
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        try body(db)
    }

    deinit {
        // Drain BUSY statements before releasing the deserialized image. A
        // failed non-BUSY close intentionally leaks the buffer rather than
        // risking a use-after-free.
        while true {
            let status = sqlite3_close(db)
            if status == SQLITE_OK { break }
            if status == SQLITE_BUSY, let statement = sqlite3_next_stmt(db, nil) {
                _ = sqlite3_finalize(statement)
                continue
            }
            return
        }
        sqlite3_free(buffer)
    }
}
