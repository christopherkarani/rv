import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// A deserialized SQLite handle and its backing allocation with one owner.
/// The database must be closed before SQLite's buffer is released.
struct OwnedSQLiteDatabase: ~Copyable {
    let db: OpaquePointer
    let buffer: UnsafeMutableRawPointer

    deinit {
        _ = sqlite3_close(db)
        sqlite3_free(buffer)
    }
}
