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

    /// Surface-extract bash `part` rows from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        let sourcePath = fileURL.path
        var events: [ExtractedEvent] = []
        try ScanSQLiteEngine.rows(
            in: data,
            sourcePath: sourcePath,
            sql: "SELECT session_id, data FROM part;"
        ) { statement in
            let sessionID = ScanSQLiteEngine.textColumn(statement, index: 0)
            guard let dataText = ScanSQLiteEngine.textColumn(statement, index: 1),
                  let payload = dataText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  (object["type"] as? String) == "tool",
                  (object["tool"] as? String) == "bash",
                  let state = object["state"] as? [String: Any],
                  let input = state["input"] as? [String: Any],
                  let command = input["command"] as? String,
                  command.isEmpty == false
            else {
                return
            }
            let occurredAt = Self.date(from: state["time"])
            events.append(
                ExtractedEvent(
                    host: .opencode,
                    sessionID: sessionID.flatMap(SessionID.init(validating:)),
                    sourcePath: sourcePath,
                    occurredAt: occurredAt,
                    command: ShellCommand(rawValue: command),
                    workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(object)
                )
            )
        }
        return events
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
        return ScanTimestamp.epoch(raw, requirePositive: false)
    }
}
