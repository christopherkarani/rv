import Foundation
import RVDomain
#if canImport(SQLite3)
import SQLite3
#endif

/// Fail-closed Hermes store I/O. Empty, invalid, or unprepared database
/// bytes are an error, not a successful empty event list.
public enum HermesStoreError: Error, Sendable, Equatable {
    /// `data` is empty, not SQLite, or could not be opened.
    case unreadable(sourcePath: String)
    /// Database opened but the `messages` query could not be prepared.
    case prepareFailed(sourcePath: String)
}

/// Hermes session store at `$HOME/.hermes/state.db`.
/// Surface field: `messages.tool_calls` (JSON) with a `terminal` tool call
/// (`function.name` / `name` == `terminal`, and `arguments.command`).
public struct HermesStoreAdapter: SessionStoreAdapter {
    public var host: ScanHostID { .hermes }

    public init() {}

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".hermes", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        fileURL.lastPathComponent == "state.db"
    }

    /// Surface-extract terminal events from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try Self.events(in: data, sourcePath: fileURL.path)
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    private static func events(in data: Data, sourcePath: String) throws -> [ExtractedEvent] {
        let opened = try deserializedDatabase(from: data, sourcePath: sourcePath)

        let sql = "SELECT session_id, tool_calls, timestamp FROM messages;"
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(opened.db, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            if statement != nil { _ = sqlite3_finalize(statement) }
            switch prepareStatus {
            case SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_CANTOPEN:
                throw HermesStoreError.unreadable(sourcePath: sourcePath)
            default:
                throw HermesStoreError.prepareFailed(sourcePath: sourcePath)
            }
        }
        defer { _ = sqlite3_finalize(statement) }

        var events: [ExtractedEvent] = []
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            let sessionID = Self.textColumn(statement, index: 0)
            let occurredAt = Self.date(fromTimestamp: sqlite3_column_double(statement, 2))
            if let toolCalls = Self.textColumn(statement, index: 1) {
                for command in Self.extractCommands(from: toolCalls) {
                    events.append(
                        ExtractedEvent(
                            host: .hermes,
                            sessionID: sessionID,
                            sourcePath: sourcePath,
                            occurredAt: occurredAt,
                            command: ShellCommand(rawValue: command)
                        )
                    )
                }
            }
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw HermesStoreError.unreadable(sourcePath: sourcePath)
        }
        return events
    }

    private static func deserializedDatabase(
        from data: Data,
        sourcePath: String
    ) throws -> OwnedSQLiteDatabase {
        guard data.starts(with: sqliteHeader) else {
            throw HermesStoreError.unreadable(sourcePath: sourcePath)
        }

        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            if let db { _ = sqlite3_close(db) }
            throw HermesStoreError.unreadable(sourcePath: sourcePath)
        }

        let byteCount = data.count
        guard let raw = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            _ = sqlite3_close(db)
            throw HermesStoreError.unreadable(sourcePath: sourcePath)
        }

        let copied = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            raw.copyMemory(from: base, byteCount: byteCount)
            return true
        }
        guard copied else {
            sqlite3_free(raw)
            _ = sqlite3_close(db)
            throw HermesStoreError.unreadable(sourcePath: sourcePath)
        }

        // WAL stores write/read format 2 at header bytes 18–19. Deserialize
        // has no WAL sidecar, so those bytes must be 1 (rollback) or use
        // fails with SQLITE_CANTOPEN.
        if byteCount > 19 {
            let header = raw.assumingMemoryBound(to: UInt8.self)
            header[18] = 1
            header[19] = 1
        }

        // OwnedSQLiteDatabase closes the handle before freeing P. Do not set
        // FREEONCLOSE — SQLite frees P itself on deserialize failure when that
        // bit is set, which would double-free if we also free it.
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
            throw HermesStoreError.unreadable(sourcePath: sourcePath)
        }
        return OwnedSQLiteDatabase(db: db, buffer: raw)
    }

    private static func extractCommands(from toolCallsJSON: String) -> [String] {
        guard let data = toolCallsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }
        if let list = object as? [[String: Any]] {
            return list.compactMap(terminalCommand(in:))
        }
        if let object = object as? [String: Any],
           let command = terminalCommand(in: object) {
            return [command]
        }
        return []
    }

    private static func terminalCommand(in object: [String: Any]) -> String? {
        if isTerminal(object) {
            return commandText(in: object["arguments"])
                ?? commandText(in: object["params"])
                ?? commandText(in: object["input"])
        }
        if let function = object["function"] as? [String: Any], isTerminal(function) {
            return commandText(in: function["arguments"])
                ?? commandText(in: function["params"])
                ?? commandText(in: object["arguments"])
        }
        return nil
    }

    private static func isTerminal(_ object: [String: Any]) -> Bool {
        let name = (object["name"] as? String) ?? (object["toolName"] as? String)
        return name == "terminal"
    }

    private static func commandText(in value: Any?) -> String? {
        if let object = value as? [String: Any],
           let command = object["command"] as? String,
           command.isEmpty == false {
            return command
        }
        if let text = value as? String, text.isEmpty == false {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? String,
                  command.isEmpty == false
            else {
                return nil
            }
            return command
        }
        return nil
    }

    private static func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func date(fromTimestamp raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}
