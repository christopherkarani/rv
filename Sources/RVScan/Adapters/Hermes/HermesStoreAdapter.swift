import Foundation
import RVDomain
#if canImport(SQLite3)
import SQLite3
#endif

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
        let sourcePath = fileURL.path
        var events: [ExtractedEvent] = []
        try ScanSQLiteEngine.rows(
            in: data,
            sourcePath: sourcePath,
            sql: "SELECT session_id, tool_calls, timestamp FROM messages;"
        ) { statement in
            let sessionID = ScanSQLiteEngine.textColumn(statement, index: 0)
            let occurredAt = ScanTimestamp.epoch(sqlite3_column_double(statement, 2))
            if let toolCalls = ScanSQLiteEngine.textColumn(statement, index: 1) {
                for extracted in Self.extractCommands(from: toolCalls) {
                    events.append(
                        ExtractedEvent(
                            host: .hermes,
                            sessionID: sessionID.flatMap(SessionID.init(validating:)),
                            sourcePath: sourcePath,
                            occurredAt: occurredAt,
                            command: ShellCommand(rawValue: extracted.command),
                            workingDirectory: extracted.workingDirectory
                        )
                    )
                }
            }
        }
        return events
    }

    private struct ExtractedShell {
        var command: String
        var workingDirectory: WorkingDirectory?
    }

    private static func extractCommands(from toolCallsJSON: String) -> [ExtractedShell] {
        guard let object = JSONParse.value(toolCallsJSON) else {
            return []
        }
        if let list = object as? [[String: Any]] {
            return list.compactMap(extractedShell(in:))
        }
        if let object = object as? [String: Any],
           let extracted = extractedShell(in: object) {
            return [extracted]
        }
        return []
    }

    private static func extractedShell(in object: [String: Any]) -> ExtractedShell? {
        guard let command = terminalCommand(in: object) else { return nil }
        return ExtractedShell(
            command: command,
            workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(object)
        )
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
            guard let object = JSONParse.object(text),
                  let command = object["command"] as? String,
                  command.isEmpty == false
            else {
                return nil
            }
            return command
        }
        return nil
    }
}
