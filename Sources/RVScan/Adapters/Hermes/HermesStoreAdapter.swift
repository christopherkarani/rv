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
        guard let value = JSONParse.value(toolCallsJSON) else {
            return []
        }
        if let list = value.asArray, list.allSatisfy({ $0.asObject != nil }) {
            return list.compactMap(extractedShell(in:))
        }
        if let extracted = extractedShell(in: value) {
            return [extracted]
        }
        return []
    }

    private static func extractedShell(in value: JSONValue) -> ExtractedShell? {
        guard value.asObject != nil, let command = terminalCommand(in: value) else { return nil }
        return ExtractedShell(
            command: command,
            workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(value)
        )
    }

    private static func terminalCommand(in value: JSONValue) -> String? {
        if isTerminal(value) {
            return commandText(in: value["arguments"])
                ?? commandText(in: value["params"])
                ?? commandText(in: value["input"])
        }
        if let function = value["function"], function.asObject != nil, isTerminal(function) {
            return commandText(in: function["arguments"])
                ?? commandText(in: function["params"])
                ?? commandText(in: value["arguments"])
        }
        return nil
    }

    private static func isTerminal(_ value: JSONValue) -> Bool {
        guard let name = value["name"]?.string ?? value["toolName"]?.string else { return false }
        return HermesToolName(wireValue: name).looseMatch == .shell
    }

    private static func commandText(in value: JSONValue?) -> String? {
        if value?.asObject != nil,
           let command = value?["command"]?.string,
           command.isEmpty == false {
            return command
        }
        if let text = value?.string, text.isEmpty == false {
            guard let object = JSONParse.object(text),
                  let command = object["command"]?.string,
                  command.isEmpty == false
            else {
                return nil
            }
            return command
        }
        return nil
    }
}
