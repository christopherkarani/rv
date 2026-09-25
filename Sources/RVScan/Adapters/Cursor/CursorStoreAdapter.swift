import Foundation
import RVDomain

/// Cursor session store at `$HOME/.cursor/projects/**/agent-transcripts/*.jsonl`.
/// Surface fields: official `beforeShellExecution.command` and `preToolUse` /
/// `Shell` `tool_input.command`. `extract(fileURL:data:)` uses **`data`**.
public struct CursorStoreAdapter: SessionStoreAdapter {
    public var host: ScanHostID { .cursor }

    private static let shellTools: Set<String> = [
        "Shell",
        "Bash",
        "shell",
        "bash",
    ]

    public init() {}

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".cursor/projects", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        let path = fileURL.path
        return path.contains("/agent-transcripts/") && fileURL.pathExtension == "jsonl"
    }

    /// Surface-extract shell events from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    ///
    /// Per-file failure policy (fail-closed, unchanged): throws `unreadable`
    /// when `data` is empty, not UTF-8, or contains no usable line. A line is
    /// usable exactly when it is a JSON object — wrong-typed fields decode as
    /// nil instead of failing the line. Bad lines and unknown shapes
    /// contribute zero events without aborting the file. Lines split on LF
    /// only: bare-CR separators no longer split (the old `\.isNewline` split
    /// did), so a CR-only file yields no usable line and throws.
    public func extract(fileURL: URL, data: Data) throws(SessionStoreError) -> [ExtractedEvent] {
        try Self.events(
            in: data,
            sourcePath: fileURL.path,
            fallbackSession: Self.sessionID(from: fileURL)
        )
    }

    private static func sessionID(from fileURL: URL) -> SessionID? {
        SessionID(validating: fileURL.deletingPathExtension().lastPathComponent)
    }

    private static func events(
        in data: Data,
        sourcePath: String,
        fallbackSession: SessionID?
    ) throws(SessionStoreError) -> [ExtractedEvent] {
        guard data.isEmpty == false else {
            throw SessionStoreError.unreadable(host: .cursor, sourcePath: sourcePath)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SessionStoreError.unreadable(host: .cursor, sourcePath: sourcePath)
        }

        var events: [ExtractedEvent] = []
        var sawUsableLine = false
        for line in ScanJSONLines.lines(from: data) {
            guard let storeLine = ScanJSONLines.decode(CursorStoreLine.self, from: line) else {
                continue
            }
            sawUsableLine = true
            for command in commands(in: storeLine) {
                events.append(
                    ExtractedEvent(
                        host: .cursor,
                        sessionID: sessionID(in: storeLine) ?? fallbackSession,
                        sourcePath: sourcePath,
                        occurredAt: occurredAt(in: storeLine),
                        command: ShellCommand(rawValue: command),
                        workingDirectory: storeLine.workingDirectory
                    )
                )
            }
        }
        if sawUsableLine == false {
            throw SessionStoreError.unreadable(host: .cursor, sourcePath: sourcePath)
        }
        return events
    }

    private static func sessionID(in line: CursorStoreLine) -> SessionID? {
        if let value = line.conversationID, let id = SessionID(validating: value) {
            return id
        }
        if let value = line.sessionSnake, let id = SessionID(validating: value) {
            return id
        }
        if let value = line.sessionCamel, let id = SessionID(validating: value) {
            return id
        }
        return nil
    }

    private static func commands(in line: CursorStoreLine) -> [String] {
        if let command = hookCommand(in: line) {
            return [command]
        }
        return []
    }

    private static func hookCommand(in line: CursorStoreLine) -> String? {
        let event = line.hookEventSnake ?? line.hookEventCamel
        if event == "beforeShellExecution" || event == nil {
            if let command = line.command, command.isEmpty == false {
                return command
            }
        }
        if event == nil || event == "preToolUse" || event == "PreToolUse" {
            let name = line.toolSnake ?? line.toolCamel
            guard let name, shellTools.contains(name) else { return nil }
            return commandText(from: line.toolInputSnake ?? line.toolInputCamel)
        }
        return nil
    }

    /// Old Cursor branch: an object yields its string `command` (arrays
    /// ignored), a string yields itself literally (never re-parsed as JSON).
    private static func commandText(from value: CursorValue?) -> String? {
        switch value {
        case .object(let input):
            guard let command = input.command, command.isEmpty == false else { return nil }
            return command
        case .text(let text):
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    /// `timestamp` shadows `ts` whenever present (even when unparseable).
    /// Unlike Codex, numeric timestamps are ignored, not parsed as epochs.
    private static func occurredAt(in line: CursorStoreLine) -> Date? {
        if let timestamp = line.timestamp {
            if case .text(let raw) = timestamp {
                return ScanTimestamp.parse(raw)
            }
            return nil
        }
        if let ts = line.ts {
            if case .text(let raw) = ts {
                return ScanTimestamp.parse(raw)
            }
            return nil
        }
        return nil
    }
}

/// One JSONL line of the Cursor session store. Covers exactly the fields
/// extraction reads: timestamps, session ids, hook/tool routing, the direct
/// `command`, tool input, and cwd-ish fields.
///
/// Lenient: every field decodes with `try?`, so any JSON object yields a line
/// and only non-object lines fail to decode — the typed equivalent of the old
/// `as? [String: Any]` line check. Explicit JSON null decodes as absent.
private struct CursorStoreLine: Decodable {
    var timestamp: CursorValue?
    var ts: CursorValue?
    var conversationID: String?
    var sessionSnake: String?
    var sessionCamel: String?
    var hookEventSnake: String?
    var hookEventCamel: String?
    var command: String?
    var toolSnake: String?
    var toolCamel: String?
    var toolInputSnake: CursorValue?
    var toolInputCamel: CursorValue?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Nested-first cwd over the modeled carriers, then the envelope fields —
    /// the typed replacement for this adapter's share of the old deep crawl
    /// (which also probed unmodeled `params`/`args`/`state`/`function` keys and
    /// recursed below depth 1; those exotic nestings now read as absent).
    var workingDirectory: WorkingDirectory? {
        toolInputCamel?.nestedWorkingDirectory
            ?? toolInputSnake?.nestedWorkingDirectory
            ?? ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case ts
        case conversationID = "conversation_id"
        case sessionSnake = "session_id"
        case sessionCamel = "sessionId"
        case hookEventSnake = "hook_event_name"
        case hookEventCamel = "hookEventName"
        case command
        case toolSnake = "tool_name"
        case toolCamel = "toolName"
        case toolInputSnake = "tool_input"
        case toolInputCamel = "toolInput"
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try? container.decode(CursorValue.self, forKey: .timestamp)
        ts = try? container.decode(CursorValue.self, forKey: .ts)
        conversationID = try? container.decode(String.self, forKey: .conversationID)
        sessionSnake = try? container.decode(String.self, forKey: .sessionSnake)
        sessionCamel = try? container.decode(String.self, forKey: .sessionCamel)
        hookEventSnake = try? container.decode(String.self, forKey: .hookEventSnake)
        hookEventCamel = try? container.decode(String.self, forKey: .hookEventCamel)
        command = try? container.decode(String.self, forKey: .command)
        toolSnake = try? container.decode(String.self, forKey: .toolSnake)
        toolCamel = try? container.decode(String.self, forKey: .toolCamel)
        toolInputSnake = try? container.decode(CursorValue.self, forKey: .toolInputSnake)
        toolInputCamel = try? container.decode(CursorValue.self, forKey: .toolInputCamel)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// A tool-input/timestamp carrier: string, object, or inert.
/// Total: every JSON value decodes (numbers/bools/null/arrays become `.other`),
/// so a present key keeps shadowing its fallback exactly like the old `??` lookups.
private enum CursorValue: Decodable {
    case text(String)
    case object(CursorToolInput)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        if let value = try? container.decode(CursorToolInput.self) {
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
        if (try? container.decode([CursorInertJSON].self)) != nil {
            self = .other
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    /// Direct cwd-ish fields of an object carrier, or of a JSON-encoded object
    /// string, mirroring the old nested-object and JSON-string crawl one level deep.
    var nestedWorkingDirectory: WorkingDirectory? {
        switch self {
        case .object(let input):
            return input.workingDirectory
        case .text(let text):
            guard let data = text.data(using: .utf8),
                  let input = try? JSONDecoder().decode(CursorToolInput.self, from: data)
            else {
                return nil
            }
            return input.workingDirectory
        case .other:
            return nil
        }
    }
}

/// A tool-input object: the string `command` plus cwd-ish fields.
/// Lenient: any JSON object decodes; wrong-typed fields become nil.
private struct CursorToolInput: Decodable {
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

/// Total consumer for array payloads, which carry no command or cwd.
private struct CursorInertJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([CursorInertJSON].self)) != nil { return }
        if (try? container.decode([String: CursorInertJSON].self)) != nil { return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }
}
