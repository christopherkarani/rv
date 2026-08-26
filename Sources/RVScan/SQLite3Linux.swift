#if !canImport(SQLite3)
/// Official Swift 6.3.3 Linux has no `SQLite3` clang module. OpenCode still
/// talks system `libsqlite3` (no SPM package) via these C entry points.
typealias sqlite3_destructor_type = @convention(c) (UnsafeMutableRawPointer?) -> Void

let SQLITE_OK: Int32 = 0
let SQLITE_CORRUPT: Int32 = 11
let SQLITE_CANTOPEN: Int32 = 14
let SQLITE_NOTADB: Int32 = 26
let SQLITE_ROW: Int32 = 100
let SQLITE_DONE: Int32 = 101
let SQLITE_OPEN_READONLY: Int32 = 0x00000001
let SQLITE_OPEN_URI: Int32 = 0x00000040
let SQLITE_DESERIALIZE_FREEONCLOSE: Int32 = 1
let SQLITE_DESERIALIZE_READONLY: Int32 = 4

typealias sqlite3_int64 = Int64
typealias sqlite3_uint64 = UInt64

@_silgen_name("sqlite3_open")
func sqlite3_open(
    _ filename: UnsafePointer<CChar>?,
    _ ppDb: UnsafeMutablePointer<OpaquePointer?>?
) -> Int32

@_silgen_name("sqlite3_open_v2")
func sqlite3_open_v2(
    _ filename: UnsafePointer<CChar>?,
    _ ppDb: UnsafeMutablePointer<OpaquePointer?>?,
    _ flags: Int32,
    _ zVfs: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("sqlite3_close")
func sqlite3_close(_ db: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_exec")
func sqlite3_exec(
    _ db: OpaquePointer?,
    _ sql: UnsafePointer<CChar>?,
    _ callback: (
        @convention(c) (
            UnsafeMutableRawPointer?,
            Int32,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        ) -> Int32
    )?,
    _ pArg: UnsafeMutableRawPointer?,
    _ errmsg: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_prepare_v2")
func sqlite3_prepare_v2(
    _ db: OpaquePointer?,
    _ zSql: UnsafePointer<CChar>?,
    _ nByte: Int32,
    _ ppStmt: UnsafeMutablePointer<OpaquePointer?>?,
    _ pzTail: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_finalize")
func sqlite3_finalize(_ pStmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_step")
func sqlite3_step(_ pStmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_column_text")
func sqlite3_column_text(_ pStmt: OpaquePointer?, _ iCol: Int32) -> UnsafePointer<UInt8>?

@_silgen_name("sqlite3_bind_text")
func sqlite3_bind_text(
    _ pStmt: OpaquePointer?,
    _ index: Int32,
    _ value: UnsafePointer<CChar>?,
    _ n: Int32,
    _ destructor: sqlite3_destructor_type?
) -> Int32

@_silgen_name("sqlite3_malloc64")
func sqlite3_malloc64(_ n: sqlite3_uint64) -> UnsafeMutableRawPointer?

@_silgen_name("sqlite3_free")
func sqlite3_free(_ p: UnsafeMutableRawPointer?)

@_silgen_name("sqlite3_deserialize")
func sqlite3_deserialize(
    _ db: OpaquePointer?,
    _ zSchema: UnsafePointer<CChar>?,
    _ pData: UnsafeMutablePointer<UInt8>?,
    _ szDb: sqlite3_int64,
    _ szBuf: sqlite3_int64,
    _ mFlags: UInt32
) -> Int32
#endif
