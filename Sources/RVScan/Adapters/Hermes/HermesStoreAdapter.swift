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
    ///
    /// Per-row failure policy (best-effort, unchanged): undecodable
    /// `tool_calls` payloads and unknown shapes contribute zero events without
    /// aborting the file; only store I/O failures throw.
    public func extract(fileURL: URL, data: Data) throws(SessionStoreError) -> [ExtractedEvent] {
        do {
            return try Self.events(in: data, sourcePath: fileURL.path)
        } catch let error as SessionStoreError {
            throw error
        } catch {
            // Unreachable: `events` only throws `SessionStoreError` values, and
            // `withConnection` only rethrows what its body throws.
            throw SessionStoreError.unreadable(host: .hermes, sourcePath: fileURL.path)
        }
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    private static func events(in data: Data, sourcePath: String) throws -> [ExtractedEvent] {
        let opened = try deserializedDatabase(from: data, sourcePath: sourcePath)

        // Keep SQLite statement use inside the borrow; the owner stays alive
        // until this closure finalizes every statement and returns.
        return try opened.withConnection { db in
            let sql = "SELECT session_id, tool_calls, timestamp FROM messages;"
            var statement: OpaquePointer?
            let prepareStatus = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard prepareStatus == SQLITE_OK, let statement else {
                if statement != nil { _ = sqlite3_finalize(statement) }
                switch prepareStatus {
                case SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_CANTOPEN:
                    throw SessionStoreError.unreadable(host: .hermes, sourcePath: sourcePath)
                default:
                    throw SessionStoreError.queryFailed(host: .hermes, sourcePath: sourcePath)
                }
            }
            defer { _ = sqlite3_finalize(statement) }

            var events: [ExtractedEvent] = []
            var stepStatus = sqlite3_step(statement)
            while stepStatus == SQLITE_ROW {
                let sessionID = Self.textColumn(statement, index: 0)
                let occurredAt = Self.date(fromTimestamp: sqlite3_column_double(statement, 2))
                if let toolCalls = Self.textColumn(statement, index: 1) {
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
                stepStatus = sqlite3_step(statement)
            }
            guard stepStatus == SQLITE_DONE else {
                throw SessionStoreError.unreadable(host: .hermes, sourcePath: sourcePath)
            }
            return events
        }
    }

    private static func deserializedDatabase(
        from data: Data,
        sourcePath: String
    ) throws -> OwnedSQLiteDatabase {
        guard data.starts(with: sqliteHeader) else {
            throw SessionStoreError.unreadable(host: .hermes, sourcePath: sourcePath)
        }

        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            if let db { _ = sqlite3_close(db) }
            throw SessionStoreError.unreadable(host: .hermes, sourcePath: sourcePath)
        }

        let byteCount = data.count
        guard let raw = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            _ = sqlite3_close(db)
            throw SessionStoreError.unreadable(host: .hermes, sourcePath: sourcePath)
        }

        let copied = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            raw.copyMemory(from: base, byteCount: byteCount)
            return true
        }
        guard copied else {
            sqlite3_free(raw)
            _ = sqlite3_close(db)
            throw SessionStoreError.unreadable(host: .hermes, sourcePath: sourcePath)
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
            throw SessionStoreError.unreadable(host: .hermes, sourcePath: sourcePath)
        }
        return OwnedSQLiteDatabase(db: db, buffer: raw)
    }

    /// Old `extractCommands(from:)`: a `tool_calls` payload is a list of calls
    /// or a single call; anything else contributes zero events. A non-object
    /// element still fails a list payload, matching the old
    /// `as? [[String: Any]]` row check.
    private static func extractCommands(from toolCallsJSON: String) -> [ScanExtractedShell] {
        guard let payload = toolCallsJSON.data(using: .utf8) else { return [] }
        if let list = try? JSONDecoder().decode([HermesToolCall].self, from: payload) {
            return list.compactMap(extractedShell(in:))
        }
        if let object = try? JSONDecoder().decode(HermesToolCall.self, from: payload),
           let extracted = extractedShell(in: object) {
            return [extracted]
        }
        return []
    }

    private static func extractedShell(in call: HermesToolCall) -> ScanExtractedShell? {
        guard let command = terminalCommand(in: call) else { return nil }
        return ScanExtractedShell(
            command: command,
            workingDirectory: call.workingDirectory
        )
    }

    /// Old `terminalCommand(in:)`: a `terminal` call reads `arguments` →
    /// `params` → `input`; otherwise a `terminal` function reads its own
    /// `arguments` → `params`, then the outer `arguments` — never the outer
    /// `params`/`input`, and never `function.input`.
    private static func terminalCommand(in call: HermesToolCall) -> String? {
        if isTerminal(name: call.name, toolName: call.toolName) {
            return commandText(in: call.arguments)
                ?? commandText(in: call.params)
                ?? commandText(in: call.input)
        }
        if let function = call.function,
           isTerminal(name: function.name, toolName: function.toolName) {
            return commandText(in: function.arguments)
                ?? commandText(in: function.params)
                ?? commandText(in: call.arguments)
        }
        return nil
    }

    private static func isTerminal(name: String?, toolName: String?) -> Bool {
        (name ?? toolName) == "terminal"
    }

    /// Old `commandText(in:)`: an object yields its non-empty string `command`;
    /// a string is re-parsed as JSON and yields the object's non-empty string
    /// `command`; an empty command is inert and falls through like a miss.
    private static func commandText(in value: HermesCommandValue?) -> String? {
        switch value {
        case .object(let input):
            guard let command = input.command, command.isEmpty == false else {
                return nil
            }
            return command
        case .text(let raw):
            guard let payload = raw.data(using: .utf8),
                  let input = try? JSONDecoder().decode(HermesCommandInput.self, from: payload),
                  let command = input.command, command.isEmpty == false
            else {
                return nil
            }
            return command
        case .other, nil:
            return nil
        }
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

/// One tool call of a Hermes `messages.tool_calls` payload (a list of calls
/// or a single call). Covers exactly the fields extraction reads: the
/// terminal routing names, the command carriers, the nested function, and
/// cwd-ish fields.
///
/// Lenient: every field decodes with `try?`, so any JSON object yields a call
/// and only non-object payloads fail to decode — the typed equivalent of the
/// old `as? [String: Any]` row check. Explicit JSON null decodes as absent.
private struct HermesToolCall: Decodable {
    var name: String?
    var toolName: String?
    var arguments: HermesCommandValue?
    var params: HermesCommandValue?
    var input: HermesCommandValue?
    var function: HermesFunction?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Cwd in the old crawl's probe order over the modeled carriers (`params`,
    /// then `input`, then `arguments`, then the `function` subtree — not
    /// command-fallthrough order), then the envelope fields. The typed
    /// replacement for this adapter's share of the old deep crawl (which also
    /// probed unmodeled `args`/`toolInput`/`state`/`payload` keys and recursed
    /// below depth 1; those exotic nestings now read as absent).
    var workingDirectory: WorkingDirectory? {
        params?.nestedWorkingDirectory
            ?? input?.nestedWorkingDirectory
            ?? arguments?.nestedWorkingDirectory
            ?? function?.workingDirectory
            ?? ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case toolName
        case arguments
        case params
        case input
        case function
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
        arguments = try? container.decode(HermesCommandValue.self, forKey: .arguments)
        params = try? container.decode(HermesCommandValue.self, forKey: .params)
        input = try? container.decode(HermesCommandValue.self, forKey: .input)
        function = try? container.decode(HermesFunction.self, forKey: .function)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// A nested function call: the terminal routing names plus its own command
/// carriers and cwd-ish fields. Command routing reads `arguments`/`params`
/// only — never `input`, which the old code never subscripted here.
/// Lenient: any JSON object decodes; wrong-typed fields become nil.
private struct HermesFunction: Decodable {
    var name: String?
    var toolName: String?
    var arguments: HermesCommandValue?
    var params: HermesCommandValue?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Direct cwd-ish fields plus the modeled carriers in crawl order. The old
    /// crawl also probed unmodeled keys (`input`, `args`, `state`, …) and
    /// recursed deeper; those exotic nestings now read as absent.
    var workingDirectory: WorkingDirectory? {
        params?.nestedWorkingDirectory
            ?? arguments?.nestedWorkingDirectory
            ?? ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case toolName
        case arguments
        case params
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        toolName = try? container.decode(String.self, forKey: .toolName)
        arguments = try? container.decode(HermesCommandValue.self, forKey: .arguments)
        params = try? container.decode(HermesCommandValue.self, forKey: .params)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// A command carrier: JSON-encoded string, object, or inert.
/// Total: every JSON value decodes (numbers/bools/null/arrays become `.other`),
/// so a wrong-typed carrier is inert and falls through, never failing the row.
private enum HermesCommandValue: Decodable {
    case text(String)
    case object(HermesCommandInput)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        if let value = try? container.decode(HermesCommandInput.self) {
            self = .object(value)
            return
        }
        if container.decodeNil() {
            self = .other
            return
        }
        if (try? container.decode(Bool.self)) != nil {
            self = .other
            return
        }
        if (try? container.decode(Double.self)) != nil {
            self = .other
            return
        }
        if (try? container.decode([HermesInertJSON].self)) != nil {
            self = .other
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    /// Direct cwd-ish fields of an object carrier, or of a JSON-encoded object
    /// string, mirroring the old nested-object and JSON-string crawl one
    /// level deep.
    var nestedWorkingDirectory: WorkingDirectory? {
        switch self {
        case .object(let input):
            return input.workingDirectory
        case .text(let raw):
            guard let payload = raw.data(using: .utf8),
                  let input = try? JSONDecoder().decode(HermesCommandInput.self, from: payload)
            else {
                return nil
            }
            return input.workingDirectory
        case .other:
            return nil
        }
    }
}

/// A command-carrier object: the string `command` plus cwd-ish fields.
/// Lenient: any JSON object decodes; wrong-typed fields become nil.
private struct HermesCommandInput: Decodable {
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

/// Total consumer for array payloads, which carry no command.
private struct HermesInertJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([HermesInertJSON].self)) != nil { return }
        if (try? container.decode([String: HermesInertJSON].self)) != nil { return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }
}
