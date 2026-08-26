import Foundation
import RVDomain
#if canImport(SQLite3)
import SQLite3
#endif

/// Fail-closed OpenClaw store I/O. Empty, invalid, or unprepared database
/// bytes are an error, not a successful empty event list.
public enum OpenClawStoreError: Error, Sendable, Equatable {
    /// `data` is empty, not SQLite, or could not be opened.
    case unreadable(sourcePath: String)
    /// Database opened but the `transcript_events` query could not be prepared.
    case prepareFailed(sourcePath: String)
}

/// OpenClaw per-agent session store at
/// `$HOME/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`.
/// Surface field: `transcript_events.event_json` with an exec tool call
/// (`type` toolCall/tool_call, `name`/`toolName` == `exec`, and
/// `arguments.command` or `params.command`).
public struct OpenClawStoreAdapter: SessionStoreAdapter {
    public var host: ScanHostID { .openclaw }

    public init() {}

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".openclaw/agents", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        fileURL.lastPathComponent == "openclaw-agent.sqlite"
    }

    /// Surface-extract exec events from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try Self.events(in: data, sourcePath: fileURL.path)
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    private struct OpenedDatabase {
        let db: OpaquePointer
        let buffer: UnsafeMutableRawPointer
    }

    private static func events(in data: Data, sourcePath: String) throws -> [ExtractedEvent] {
        let opened = try deserializedDatabase(from: data, sourcePath: sourcePath)
        defer {
            _ = sqlite3_close(opened.db)
            sqlite3_free(opened.buffer)
        }

        let sql = "SELECT session_id, event_json, created_at FROM transcript_events;"
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(opened.db, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            if statement != nil { _ = sqlite3_finalize(statement) }
            switch prepareStatus {
            case SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_CANTOPEN:
                throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
            default:
                throw OpenClawStoreError.prepareFailed(sourcePath: sourcePath)
            }
        }
        defer { _ = sqlite3_finalize(statement) }

        var events: [ExtractedEvent] = []
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            let sessionID = Self.textColumn(statement, index: 0)
            guard let eventJSON = Self.textColumn(statement, index: 1),
                  let extracted = Self.extractCommand(from: eventJSON)
            else {
                stepStatus = sqlite3_step(statement)
                continue
            }
            let occurredAt = Self.date(fromCreatedAt: sqlite3_column_int64(statement, 2))
            events.append(
                ExtractedEvent(
                    host: .openclaw,
                    sessionID: sessionID,
                    sourcePath: sourcePath,
                    occurredAt: occurredAt,
                    command: ShellCommand(rawValue: extracted)
                )
            )
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
        }
        return events
    }

    private static func deserializedDatabase(
        from data: Data,
        sourcePath: String
    ) throws -> OpenedDatabase {
        guard data.starts(with: sqliteHeader) else {
            throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
        }

        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            if let db { _ = sqlite3_close(db) }
            throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
        }

        let byteCount = data.count
        guard let raw = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            _ = sqlite3_close(db)
            throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
        }

        let copied = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            raw.copyMemory(from: base, byteCount: byteCount)
            return true
        }
        guard copied else {
            sqlite3_free(raw)
            _ = sqlite3_close(db)
            throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
        }

        // WAL stores write/read format 2 at header bytes 18–19. Deserialize
        // has no WAL sidecar, so those bytes must be 1 (rollback) or use
        // fails with SQLITE_CANTOPEN.
        if byteCount > 19 {
            let header = raw.assumingMemoryBound(to: UInt8.self)
            header[18] = 1
            header[19] = 1
        }

        // Caller owns P: sqlite3_free after sqlite3_close. Do not set
        // FREEONCLOSE — SQLite frees P itself on deserialize failure
        // when that bit is set, which double-frees if we also free.
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
            throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
        }
        return OpenedDatabase(db: db, buffer: raw)
    }

    private static func extractCommand(from eventJSON: String) -> String? {
        guard let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return extractCommand(from: object)
    }

    private static func extractCommand(from object: [String: Any]) -> String? {
        if let command = execCommand(in: object) {
            return command
        }
        if let toolCall = object["toolCall"] as? [String: Any],
           let command = execCommand(in: toolCall) {
            return command
        }
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for item in content {
                if let command = extractCommand(from: item) {
                    return command
                }
            }
        }
        return nil
    }

    private static func execCommand(in object: [String: Any]) -> String? {
        let name = (object["name"] as? String) ?? (object["toolName"] as? String)
        guard name == "exec" else { return nil }
        return commandText(in: object["arguments"])
            ?? commandText(in: object["params"])
            ?? commandText(in: object["input"])
    }

    private static func commandText(in value: Any?) -> String? {
        guard let object = value as? [String: Any],
              let command = object["command"] as? String,
              command.isEmpty == false
        else {
            return nil
        }
        return command
    }

    private static func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func date(fromCreatedAt raw: sqlite3_int64) -> Date? {
        guard raw > 0 else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: Double(raw) / 1000)
        }
        return Date(timeIntervalSince1970: TimeInterval(raw))
    }
}
