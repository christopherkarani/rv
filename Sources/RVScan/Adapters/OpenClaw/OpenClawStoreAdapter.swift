import Foundation
import RVDomain
#if canImport(SQLite3)
import SQLite3
#endif

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
        let sourcePath = fileURL.path
        var events: [ExtractedEvent] = []
        try ScanSQLiteEngine.rows(
            in: data,
            sourcePath: sourcePath,
            sql: "SELECT session_id, event_json, created_at FROM transcript_events;"
        ) { statement in
            let sessionID = ScanSQLiteEngine.textColumn(statement, index: 0)
            guard let eventJSON = ScanSQLiteEngine.textColumn(statement, index: 1),
                  let extracted = Self.extractCommand(from: eventJSON)
            else {
                return
            }
            let occurredAt = ScanTimestamp.epoch(Double(sqlite3_column_int64(statement, 2)))
            events.append(
                ExtractedEvent(
                    host: .openclaw,
                    sessionID: sessionID.flatMap(SessionID.init(validating:)),
                    sourcePath: sourcePath,
                    occurredAt: occurredAt,
                    command: ShellCommand(rawValue: extracted.command),
                    workingDirectory: extracted.workingDirectory
                )
            )
        }
        return events
    }

    private struct ExtractedShell {
        var command: String
        var workingDirectory: WorkingDirectory?
    }

    private static func extractCommand(from eventJSON: String) -> ExtractedShell? {
        guard let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return extractCommand(from: object)
    }

    private static func extractCommand(from object: [String: Any]) -> ExtractedShell? {
        if let command = execCommand(in: object) {
            return ExtractedShell(
                command: command,
                workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(object)
            )
        }
        if let toolCall = object["toolCall"] as? [String: Any],
           let command = execCommand(in: toolCall) {
            return ExtractedShell(
                command: command,
                workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(toolCall)
                    ?? ScanStoreWorkingDirectory.fromEnvelope(object)
            )
        }
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for item in content {
                if let extracted = extractCommand(from: item) {
                    return extracted
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
}
