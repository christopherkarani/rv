import Foundation
import RVDomain
#if canImport(SQLite3)
import SQLite3
#endif

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

    public func extract(fileURL: URL, data _: Data) throws -> [ExtractedEvent] {
        try Self.extractParts(fromDatabaseAt: fileURL)
    }

    private static func extractParts(fromDatabaseAt fileURL: URL) throws -> [ExtractedEvent] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let openStatus = sqlite3_open_v2(fileURL.path, &db, flags, nil)
        guard openStatus == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT session_id, data FROM part;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var events: [ExtractedEvent] = []
        let sourcePath = fileURL.path
        while sqlite3_step(statement) == SQLITE_ROW {
            let sessionID = Self.textColumn(statement, index: 0)
            guard let dataText = Self.textColumn(statement, index: 1),
                  let data = dataText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
