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
    public func extract(fileURL: URL, data: Data) throws(ScanStoreError) -> [ExtractedEvent] {
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
        guard let object = JSONParse.object(eventJSON) else {
            return nil
        }
        return extractCommand(from: object)
    }

    private static func extractCommand(from value: JSONValue) -> ExtractedShell? {
        if let command = execCommand(in: value) {
            return ExtractedShell(
                command: command,
                workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(value)
            )
        }
        if let toolCall = value["toolCall"], toolCall.asObject != nil,
           let command = execCommand(in: toolCall) {
            return ExtractedShell(
                command: command,
                workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(toolCall)
                    ?? ScanStoreWorkingDirectory.fromEnvelope(value)
            )
        }
        if let message = value["message"], message.asObject != nil,
           let content = message["content"]?.asArray,
           content.allSatisfy({ $0.asObject != nil }) {
            for item in content {
                if let extracted = extractCommand(from: item) {
                    return extracted
                }
            }
        }
        return nil
    }

    private static func execCommand(in value: JSONValue) -> String? {
        let name = value["name"]?.string ?? value["toolName"]?.string
        guard name == "exec" else { return nil }
        return commandText(in: value["arguments"])
            ?? commandText(in: value["params"])
            ?? commandText(in: value["input"])
    }

    private static func commandText(in value: JSONValue?) -> String? {
        guard value?.asObject != nil,
              let command = value?["command"]?.string,
              command.isEmpty == false
        else {
            return nil
        }
        return command
    }
}
