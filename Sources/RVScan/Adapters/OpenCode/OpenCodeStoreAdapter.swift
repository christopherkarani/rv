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
                  let object = JSONParse.object(dataText),
                  object["type"]?.string == "tool",
                  object["tool"]?.string == "bash",
                  let state = object["state"], state.asObject != nil,
                  let input = state["input"], input.asObject != nil,
                  let command = input["command"]?.string,
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

    private static func date(from value: JSONValue?) -> Date? {
        guard value?.asObject != nil else { return nil }
        return ScanTimestamp.epochValue(value?["start"], requirePositive: false)
    }
}
