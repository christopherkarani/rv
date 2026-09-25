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
    ///
    /// Per-row failure policy (best-effort, unchanged): undecodable `part`
    /// payloads and unknown shapes contribute zero events without aborting
    /// the file; only store I/O failures throw.
    public func extract(fileURL: URL, data: Data) throws(SessionStoreError) -> [ExtractedEvent] {
        do {
            return try Self.events(in: data, sourcePath: fileURL.path)
        } catch let error as SessionStoreError {
            throw error
        } catch {
            // Unreachable: `events` only throws `SessionStoreError` values, and
            // `withConnection` only rethrows what its body throws.
            throw SessionStoreError.unreadable(host: .opencode, sourcePath: fileURL.path)
        }
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    private static func events(in data: Data, sourcePath: String) throws -> [ExtractedEvent] {
        let opened = try deserializedDatabase(from: data, sourcePath: sourcePath)

        // Keep SQLite statement use inside the borrow; the owner stays alive
        // until this closure finalizes every statement and returns.
        return try opened.withConnection { db in
            let sql = "SELECT session_id, data FROM part;"
            var statement: OpaquePointer?
            let prepareStatus = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard prepareStatus == SQLITE_OK, let statement else {
                if statement != nil { _ = sqlite3_finalize(statement) }
                switch prepareStatus {
                case SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_CANTOPEN:
                    throw SessionStoreError.unreadable(host: .opencode, sourcePath: sourcePath)
                default:
                    throw SessionStoreError.queryFailed(host: .opencode, sourcePath: sourcePath)
                }
            }
            defer { _ = sqlite3_finalize(statement) }

            var events: [ExtractedEvent] = []
            var stepStatus = sqlite3_step(statement)
            while stepStatus == SQLITE_ROW {
                let sessionID = Self.textColumn(statement, index: 0)
                guard let dataText = Self.textColumn(statement, index: 1),
                      let payload = dataText.data(using: .utf8),
                      let row = try? JSONDecoder().decode(OpenCodeStoreRow.self, from: payload),
                      row.type == "tool",
                      row.tool == "bash",
                      let command = row.state?.input?.command,
                      command.isEmpty == false
                else {
                    stepStatus = sqlite3_step(statement)
                    continue
                }
                let occurredAt = Self.date(from: row.state?.time?.start)
                events.append(
                    ExtractedEvent(
                        host: .opencode,
                        sessionID: sessionID.flatMap(SessionID.init(validating:)),
                        sourcePath: sourcePath,
                        occurredAt: occurredAt,
                        command: ShellCommand(rawValue: command),
                        workingDirectory: row.workingDirectory
                    )
                )
                stepStatus = sqlite3_step(statement)
            }
            guard stepStatus == SQLITE_DONE else {
                throw SessionStoreError.unreadable(host: .opencode, sourcePath: sourcePath)
            }
            return events
        }
    }

    private static func deserializedDatabase(
        from data: Data,
        sourcePath: String
    ) throws -> OwnedSQLiteDatabase {
        guard data.starts(with: sqliteHeader) else {
            throw SessionStoreError.unreadable(host: .opencode, sourcePath: sourcePath)
        }

        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            if let db { _ = sqlite3_close(db) }
            throw SessionStoreError.unreadable(host: .opencode, sourcePath: sourcePath)
        }

        let byteCount = data.count
        guard let raw = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            _ = sqlite3_close(db)
            throw SessionStoreError.unreadable(host: .opencode, sourcePath: sourcePath)
        }

        let copied = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            raw.copyMemory(from: base, byteCount: byteCount)
            return true
        }
        guard copied else {
            sqlite3_free(raw)
            _ = sqlite3_close(db)
            throw SessionStoreError.unreadable(host: .opencode, sourcePath: sourcePath)
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
            throw SessionStoreError.unreadable(host: .opencode, sourcePath: sourcePath)
        }
        return OwnedSQLiteDatabase(db: db, buffer: raw)
    }

    private static func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    /// Old `date(from:)`: `state.time.start` is epoch seconds (milliseconds
    /// above 1e12, with no positivity guard); anything else yields nil. JSON
    /// booleans decode as absent (the old NSNumber crawl read `true` as epoch
    /// 1; no real store emits boolean timestamps).
    private static func date(from start: Double?) -> Date? {
        guard let raw = start else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}

/// One `part.data` JSON payload of the OpenCode session store. Covers exactly
/// the fields extraction reads: the part type/tool routing, the state input
/// command, the state time, and cwd-ish fields at row/state/input depth.
///
/// Lenient: every field decodes with `try?`, so any JSON object yields a row
/// and only non-object payloads fail to decode — the typed equivalent of the
/// old `as? [String: Any]` row check. Explicit JSON null decodes as absent.
private struct OpenCodeStoreRow: Decodable {
    var type: String?
    var tool: String?
    var state: OpenCodeState?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Input cwd wins over state cwd wins over row cwd — the typed replacement
    /// for this adapter's share of the old deep crawl (which also probed
    /// unmodeled sibling keys, JSON-string carriers, and a top-level `input`
    /// before `state`; those exotic nestings now read as absent).
    var workingDirectory: WorkingDirectory? {
        state?.input?.workingDirectory
            ?? state?.workingDirectory
            ?? ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case tool
        case state
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    /// Field-independent leniency: a present-but-wrong-typed scalar decodes
    /// as nil (matching the old per-field `as?`) instead of failing the row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        tool = try? container.decode(String.self, forKey: .tool)
        state = try? container.decode(OpenCodeState.self, forKey: .state)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// Part state: the tool input, its time, and cwd-ish fields.
/// Lenient: any JSON object decodes; wrong-typed fields become nil.
private struct OpenCodeState: Decodable {
    var input: OpenCodeInput?
    var time: OpenCodeTime?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Direct cwd-ish fields only; the row composes input-over-state.
    var workingDirectory: WorkingDirectory? {
        ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case input
        case time
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try? container.decode(OpenCodeInput.self, forKey: .input)
        time = try? container.decode(OpenCodeTime.self, forKey: .time)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// Tool input: the string `command` plus cwd-ish fields.
/// Lenient: any JSON object decodes; wrong-typed fields become nil.
private struct OpenCodeInput: Decodable {
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

/// Part time: the epoch `start`. A wrong-typed `start` decodes as nil.
private struct OpenCodeTime: Decodable {
    var start: Double?

    enum CodingKeys: String, CodingKey {
        case start
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try? container.decode(Double.self, forKey: .start)
    }
}
