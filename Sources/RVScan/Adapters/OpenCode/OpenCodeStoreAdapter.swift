import Foundation
import RVDomain
#if canImport(SQLite3)
import SQLite3
#endif

/// Fail-closed OpenCode store I/O. Empty, invalid, or unprepared database
/// bytes are an error, not a successful empty event list.
public enum OpenCodeStoreError: Error, Sendable, Equatable {
    /// `data` is empty, not SQLite, or could not be opened.
    case unreadable(sourcePath: String)
    /// Database opened but the `part` query could not be prepared.
    case prepareFailed(sourcePath: String)
}

/// OpenCode session store at `$HOME/.local/share/opencode/opencode.db`.
/// Surface field: `part.data` JSON with `type == "tool"`, `tool == "bash"`,
/// and `state.input.command` (string).
public struct OpenCodeStoreAdapter: SessionStoreAdapter {
    public var host: ScanHostID { .opencode }

    public init() {}

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".local/share/opencode", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        fileURL.lastPathComponent == "opencode.db"
    }

    /// Surface-extract bash `part` rows from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try Self.events(in: data, sourcePath: fileURL.path)
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    private static func events(in data: Data, sourcePath: String) throws -> [ExtractedEvent] {
        let db = try deserializedDatabase(from: data, sourcePath: sourcePath)
        defer { _ = sqlite3_close(db) }

        let sql = "SELECT session_id, data FROM part;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw OpenCodeStoreError.prepareFailed(sourcePath: sourcePath)
        }
        defer { _ = sqlite3_finalize(statement) }

        var events: [ExtractedEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let sessionID = Self.textColumn(statement, index: 0)
            guard let dataText = Self.textColumn(statement, index: 1),
                  let payload = dataText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  (object["type"] as? String) == "tool",
                  (object["tool"] as? String) == "bash",
                  let state = object["state"] as? [String: Any],
                  let input = state["input"] as? [String: Any],
                  let command = input["command"] as? String,
                  command.isEmpty == false
            else {
                continue
            }
            let occurredAt = Self.date(from: state["time"])
            events.append(
                ExtractedEvent(
                    host: .opencode,
                    sessionID: sessionID,
                    sourcePath: sourcePath,
                    occurredAt: occurredAt,
                    command: ShellCommand(rawValue: command)
                )
            )
        }
        return events
    }

    private static func deserializedDatabase(
        from data: Data,
        sourcePath: String
    ) throws -> OpaquePointer {
        guard data.starts(with: sqliteHeader) else {
            throw OpenCodeStoreError.unreadable(sourcePath: sourcePath)
        }

        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            if let db { _ = sqlite3_close(db) }
            throw OpenCodeStoreError.unreadable(sourcePath: sourcePath)
        }

        let byteCount = data.count
        guard let raw = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            _ = sqlite3_close(db)
            throw OpenCodeStoreError.unreadable(sourcePath: sourcePath)
        }

        let copied = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            raw.copyMemory(from: base, byteCount: byteCount)
            return true
        }
        guard copied else {
            sqlite3_free(raw)
            _ = sqlite3_close(db)
            throw OpenCodeStoreError.unreadable(sourcePath: sourcePath)
        }

        let flags = UInt32(bitPattern: SQLITE_DESERIALIZE_READONLY | SQLITE_DESERIALIZE_FREEONCLOSE)
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
            throw OpenCodeStoreError.unreadable(sourcePath: sourcePath)
        }
        return db
    }

    private static func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func date(from value: Any?) -> Date? {
        guard let time = value as? [String: Any] else { return nil }
        let raw: Double?
        if let number = time["start"] as? NSNumber {
            raw = number.doubleValue
        } else if let number = time["start"] as? Double {
            raw = number
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}
