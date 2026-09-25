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
    ///
    /// Per-row failure policy (best-effort, unchanged): undecodable
    /// `event_json` payloads and unknown shapes contribute zero events without
    /// aborting the file; only store I/O failures throw.
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try Self.events(in: data, sourcePath: fileURL.path)
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    private static func events(in data: Data, sourcePath: String) throws -> [ExtractedEvent] {
        let opened = try deserializedDatabase(from: data, sourcePath: sourcePath)

        // Keep SQLite statement use inside the borrow; the owner stays alive
        // until this closure finalizes every statement and returns.
        return try opened.withConnection { db in
            let sql = "SELECT session_id, event_json, created_at FROM transcript_events;"
            var statement: OpaquePointer?
            let prepareStatus = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
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
                        sessionID: sessionID.flatMap(SessionID.init(validating:)),
                        sourcePath: sourcePath,
                        occurredAt: occurredAt,
                        command: ShellCommand(rawValue: extracted.command),
                        workingDirectory: extracted.workingDirectory
                    )
                )
                stepStatus = sqlite3_step(statement)
            }
            guard stepStatus == SQLITE_DONE else {
                throw OpenClawStoreError.unreadable(sourcePath: sourcePath)
            }
            return events
        }
    }

    private static func deserializedDatabase(
        from data: Data,
        sourcePath: String
    ) throws -> OwnedSQLiteDatabase {
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

        // `withConnection` keeps the owner alive while statements use the
        // deserialized image. Its deinit drains BUSY statements and frees P
        // only after close succeeds. Do not set FREEONCLOSE — SQLite frees P
        // itself on deserialize failure when that bit is set, which would
        // double-free if we also free it.
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
        return OwnedSQLiteDatabase(db: db, buffer: raw)
    }

    /// Old `extractCommand(from:)` on the decoded row: an exec match on the
    /// envelope wins, then on `toolCall`, then the first match scanning
    /// `message.content` in order (one shell per row at most).
    private static func extractCommand(from eventJSON: String) -> ScanExtractedShell? {
        guard let payload = eventJSON.data(using: .utf8),
              let row = try? JSONDecoder().decode(OpenClawStoreRow.self, from: payload)
        else {
            return nil
        }
        return extractCommand(from: row)
    }

    private static func extractCommand(from row: OpenClawStoreRow) -> ScanExtractedShell? {
        if let command = execCommand(in: row) {
            return ScanExtractedShell(
                command: command,
                workingDirectory: row.workingDirectory
            )
        }
        if let toolCall = row.toolCall,
           let command = execCommand(in: toolCall) {
            return ScanExtractedShell(
                command: command,
                workingDirectory: toolCall.workingDirectory ?? row.workingDirectory
            )
        }
        if let content = row.message?.content {
            for item in content {
                if let extracted = extractCommand(from: item) {
                    return extracted
                }
            }
        }
        return nil
    }

    /// Old `execCommand(in:)`: `name`/`toolName` routes to `exec`, then the
    /// command falls through `arguments` → `params` → `input`. Carriers are
    /// objects only — the old code never re-parsed a string carrier, so a
    /// present-but-wrong-typed carrier is inert and falls through.
    private static func execCommand(in row: OpenClawStoreRow) -> String? {
        guard (row.name ?? row.toolName) == "exec" else { return nil }
        return commandText(in: row.arguments)
            ?? commandText(in: row.params)
            ?? commandText(in: row.input)
    }

    private static func commandText(in value: OpenClawCommandInput?) -> String? {
        guard let command = value?.command, command.isEmpty == false else {
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

/// One `transcript_events.event_json` payload of the OpenClaw session store.
/// Also the shape of nested `toolCall` objects and `message.content` items,
/// hence a class: matching recurses into both. Covers exactly the fields
/// extraction reads: the exec routing names, the command carriers, the nested
/// match sites, and cwd-ish fields.
///
/// Lenient: every field decodes with `try?`, so any JSON object yields a row
/// and only non-object payloads fail to decode — the typed equivalent of the
/// old `as? [String: Any]` row check. Explicit JSON null decodes as absent.
private final class OpenClawStoreRow: Decodable {
    var name: String?
    var toolName: String?
    var arguments: OpenClawCommandInput?
    var params: OpenClawCommandInput?
    var input: OpenClawCommandInput?
    var toolCall: OpenClawStoreRow?
    var message: OpenClawStoreMessage?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Cwd in the old crawl's probe order over the modeled carriers (`params`,
    /// then `input`, then `arguments` — not command-fallthrough order), then
    /// the envelope fields. The typed replacement for this adapter's share of
    /// the old deep crawl (which also probed unmodeled `args`/`toolInput`/
    /// `state`/`payload`/`function` keys, JSON-string carriers, and recursed
    /// below depth 1; those exotic nestings now read as absent).
    var workingDirectory: WorkingDirectory? {
        params?.workingDirectory
            ?? input?.workingDirectory
            ?? arguments?.workingDirectory
            ?? ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case toolName
        case arguments
        case params
        case input
        case toolCall
        case message
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    /// Field-independent leniency: a present-but-wrong-typed scalar decodes
    /// as nil (matching the old per-field `as?`) instead of failing the row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        toolName = try? container.decode(String.self, forKey: .toolName)
        arguments = try? container.decode(OpenClawCommandInput.self, forKey: .arguments)
        params = try? container.decode(OpenClawCommandInput.self, forKey: .params)
        input = try? container.decode(OpenClawCommandInput.self, forKey: .input)
        toolCall = try? container.decode(OpenClawStoreRow.self, forKey: .toolCall)
        message = try? container.decode(OpenClawStoreMessage.self, forKey: .message)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// A message wrapper: only its content items participate in matching.
/// Lenient: any JSON object decodes; a wrong-typed `content` becomes nil. A
/// non-object element still fails the enclosing `content` array, matching the
/// old `as? [[String: Any]]` row check.
private struct OpenClawStoreMessage: Decodable {
    var content: [OpenClawStoreRow]?

    enum CodingKeys: String, CodingKey {
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try? container.decode([OpenClawStoreRow].self, forKey: .content)
    }
}

/// A command carrier (`arguments`, `params`, or `input`): the string `command`
/// plus cwd-ish fields. Lenient: any JSON object decodes; wrong-typed fields
/// become nil.
private struct OpenClawCommandInput: Decodable {
    var command: String?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    var workingDirectory: WorkingDirectory? {
        ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case command
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try? container.decode(String.self, forKey: .command)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}
