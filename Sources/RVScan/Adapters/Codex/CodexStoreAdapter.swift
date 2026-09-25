import Foundation
import RVDomain

/// Fail-closed Codex store I/O. Empty or non-UTF-8 bytes are an error,
/// not a successful empty event list.
public enum CodexStoreError: Error, Sendable, Equatable {
    /// `data` is empty, not UTF-8, or wholly unreadable as JSONL.
    case unreadable(sourcePath: String)
}

/// Codex session store at `$HOME/.codex/sessions/**/rollout-*.jsonl`.
/// Surface fields: `tool_name` / `function_call.name` Bash (or `shell`) with
/// `tool_input.command` / `arguments.command`.
public struct CodexStoreAdapter: SessionStoreAdapter {
    public var host: ScanHostID { .codex }

    private static let shellTools: Set<String> = [
        "Bash",
        "bash",
        "shell",
        "local_shell",
    ]

    public init() {}

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".codex/sessions", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// Surface-extract Bash events from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    ///
    /// Per-file failure policy (fail-closed, unchanged): throws `unreadable`
    /// when `data` is empty, not UTF-8, or contains no usable line. A line is
    /// usable exactly when it is a JSON object — wrong-typed fields decode as
    /// nil instead of failing the line. Bad lines and unknown shapes
    /// contribute zero events without aborting the file. Lines split on LF
    /// only: bare-CR separators no longer split (the old `\.isNewline` split
    /// did), so a CR-only file yields no usable line and throws.
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try Self.events(in: data, sourcePath: fileURL.path, fallbackSession: Self.sessionID(from: fileURL))
    }

    private static func sessionID(from fileURL: URL) -> SessionID? {
        SessionID(validating: fileURL.deletingPathExtension().lastPathComponent)
    }

    private static func events(
        in data: Data,
        sourcePath: String,
        fallbackSession: SessionID?
    ) throws -> [ExtractedEvent] {
        guard data.isEmpty == false else {
            throw CodexStoreError.unreadable(sourcePath: sourcePath)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw CodexStoreError.unreadable(sourcePath: sourcePath)
        }

        var events: [ExtractedEvent] = []
        var sawUsableLine = false
        for line in ScanJSONLines.lines(from: data) {
            guard let storeLine = ScanJSONLines.decode(CodexStoreLine.self, from: line) else {
                continue
            }
            sawUsableLine = true
            for command in commands(in: storeLine) {
                events.append(
                    ExtractedEvent(
                        host: .codex,
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
            throw CodexStoreError.unreadable(sourcePath: sourcePath)
        }
        return events
    }

    private static func sessionID(in node: CodexStoreLine) -> SessionID? {
        if let value = node.sessionSnake, let id = SessionID(validating: value) {
            return id
        }
        if let value = node.sessionCamel, let id = SessionID(validating: value) {
            return id
        }
        if let payload = node.payload?.line {
            return sessionID(in: payload)
        }
        return nil
    }

    /// At most one command per line: the envelope hook, else the nested
    /// payload's result (returned as-is, even when empty), else the envelope
    /// function call. A present-but-empty payload shadows the envelope call.
    private static func commands(in node: CodexStoreLine) -> [String] {
        if let command = hookCommand(in: node) {
            return [command]
        }
        if let payload = node.payload?.line {
            return commands(in: payload)
        }
        if let command = functionCallCommand(in: node) {
            return [command]
        }
        return []
    }

    private static func hookCommand(in node: CodexStoreLine) -> String? {
        let event = node.hookEventSnake ?? node.hookEventCamel
        guard event == nil || event == "PreToolUse" else { return nil }
        let name = node.toolSnake ?? node.toolCamel
        guard let name, shellTools.contains(name) else { return nil }
        return commandText(from: node.toolInputSnake ?? node.toolInputCamel)
    }

    private static func functionCallCommand(in node: CodexStoreLine) -> String? {
        if node.type == "function_call" || node.type == "tool_use" {
            let name = node.name ?? node.toolCamel
            guard let name, shellTools.contains(name) else { return nil }
            return commandText(from: node.arguments ?? node.input ?? node.toolInputSnake)
        }
        if node.type == "exec_command_begin" || node.type == "exec_command" {
            return commandText(from: node.command)
        }
        return nil
    }

    private static func commandText(from value: CodexValue?) -> String? {
        switch value {
        case .text(let text):
            guard text.isEmpty == false else { return nil }
            // The old code re-parsed the string with JSONSerialization without
            // allowFragments: only a top-level array or object re-parses;
            // anything else (including JSON scalars) keeps the literal text.
            if let data = text.data(using: .utf8) {
                // One function-local decoder for both attempts: thread-confined,
                // so sharing is safe (JSONDecoder is not thread-safe in general).
                let decoder = JSONDecoder()
                if let array = try? decoder.decode([CodexValue].self, from: data) {
                    return joinedTokens(array)
                }
                if let object = try? decoder.decode([String: CodexValue].self, from: data) {
                    return commandFromMap(object)
                }
            }
            return text
        case .list(let items):
            return joinedTokens(items)
        case .map(let object):
            return commandFromMap(object)
        case .number, .other, nil:
            return nil
        }
    }

    /// Old object branch: only a string or token array under `command` counts —
    /// anything else (including a nested object) yields nil, and a string is
    /// returned literally, never re-parsed as JSON.
    private static func commandFromMap(_ object: [String: CodexValue]) -> String? {
        switch object["command"] {
        case .text(let text):
            return text.isEmpty ? nil : text
        case .list(let items):
            return joinedTokens(items)
        default:
            return nil
        }
    }

    /// Old array branch: direct string elements joined with spaces.
    private static func joinedTokens(_ items: [CodexValue]) -> String? {
        let tokens = items.compactMap { item -> String? in
            if case .text(let text) = item, text.isEmpty == false { return text }
            return nil
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }

    /// `timestamp` shadows `ts` whenever present (even when unparseable).
    private static func occurredAt(in node: CodexStoreLine) -> Date? {
        if let timestamp = node.timestamp {
            return parseTimestamp(timestamp)
        }
        if let ts = node.ts {
            return parseTimestamp(ts)
        }
        return nil
    }

    private static func parseTimestamp(_ value: CodexValue) -> Date? {
        switch value {
        case .text(let raw):
            return ScanTimestamp.parse(raw)
        case .number(let raw):
            guard raw > 0 else { return nil }
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            return Date(timeIntervalSince1970: raw)
        default:
            return nil
        }
    }
}

/// One JSONL line of the Codex session store. Also the shape of nested
/// `payload` objects, hence the `indirect`-enum payload box below: payloads
/// nest recursively, which a struct cannot express directly. Covers exactly
/// the fields extraction reads: timestamps, session ids, hook/tool routing,
/// command carriers, and cwd-ish fields.
///
/// Lenient: every field decodes with `try?`, so any JSON object yields a node
/// and only non-object lines fail to decode — the typed equivalent of the old
/// `as? [String: Any]` line check. Explicit JSON null decodes as absent.
private struct CodexStoreLine: Decodable {
    var timestamp: CodexValue?
    var ts: CodexValue?
    var sessionSnake: String?
    var sessionCamel: String?
    var hookEventSnake: String?
    var hookEventCamel: String?
    var toolSnake: String?
    var toolCamel: String?
    var toolInputSnake: CodexValue?
    var toolInputCamel: CodexValue?
    var payload: CodexPayload?
    var type: String?
    var name: String?
    var arguments: CodexValue?
    var input: CodexValue?
    var command: CodexValue?
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
            ?? input?.nestedWorkingDirectory
            ?? arguments?.nestedWorkingDirectory
            ?? payload?.line.workingDirectory
            ?? ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case ts
        case sessionSnake = "session_id"
        case sessionCamel = "sessionId"
        case hookEventSnake = "hook_event_name"
        case hookEventCamel = "hookEventName"
        case toolSnake = "tool_name"
        case toolCamel = "toolName"
        case toolInputSnake = "tool_input"
        case toolInputCamel = "toolInput"
        case payload
        case type
        case name
        case arguments
        case input
        case command
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try? container.decode(CodexValue.self, forKey: .timestamp)
        ts = try? container.decode(CodexValue.self, forKey: .ts)
        sessionSnake = try? container.decode(String.self, forKey: .sessionSnake)
        sessionCamel = try? container.decode(String.self, forKey: .sessionCamel)
        hookEventSnake = try? container.decode(String.self, forKey: .hookEventSnake)
        hookEventCamel = try? container.decode(String.self, forKey: .hookEventCamel)
        toolSnake = try? container.decode(String.self, forKey: .toolSnake)
        toolCamel = try? container.decode(String.self, forKey: .toolCamel)
        toolInputSnake = try? container.decode(CodexValue.self, forKey: .toolInputSnake)
        toolInputCamel = try? container.decode(CodexValue.self, forKey: .toolInputCamel)
        payload = try? container.decode(CodexPayload.self, forKey: .payload)
        type = try? container.decode(String.self, forKey: .type)
        name = try? container.decode(String.self, forKey: .name)
        arguments = try? container.decode(CodexValue.self, forKey: .arguments)
        input = try? container.decode(CodexValue.self, forKey: .input)
        command = try? container.decode(CodexValue.self, forKey: .command)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// Recursive `payload` chain without a reference type: `indirect` supplies
/// the indirection a struct cannot. Decodes exactly one nested line, so
/// present-but-wrong-typed payloads still decode as absent via `try?`.
private indirect enum CodexPayload: Decodable {
    case line(CodexStoreLine)

    init(from decoder: Decoder) throws {
        self = .line(try CodexStoreLine(from: decoder))
    }

    var line: CodexStoreLine {
        switch self {
        case .line(let line):
            return line
        }
    }
}

/// A command/timestamp carrier: string, epoch number, token array, or object.
/// Total: every JSON value decodes (bools/null become `.other`), so a present
/// key keeps shadowing its fallback exactly like the old `??` lookups.
private enum CodexValue: Decodable {
    case text(String)
    case number(Double)
    case list([CodexValue])
    case map([String: CodexValue])
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode([CodexValue].self) {
            self = .list(value)
            return
        }
        if let value = try? container.decode([String: CodexValue].self) {
            self = .map(value)
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
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    /// Direct cwd-ish string fields of an object carrier, or of a JSON-encoded
    /// object string (e.g. `function_call` arguments), mirroring the old
    /// nested-object and JSON-string crawl one level deep.
    var nestedWorkingDirectory: WorkingDirectory? {
        switch self {
        case .map(let object):
            return Self.cwdFields(from: object)
        case .text(let text):
            guard let data = text.data(using: .utf8),
                  let object = try? JSONDecoder().decode([String: CodexValue].self, from: data)
            else {
                return nil
            }
            return Self.cwdFields(from: object)
        default:
            return nil
        }
    }

    private static func cwdFields(from object: [String: CodexValue]) -> WorkingDirectory? {
        ScanStoreWorkingDirectory.firstValid(
            object["cwd"]?.stringValue,
            object["workdir"]?.stringValue,
            object["workingDirectory"]?.stringValue,
            object["working_directory"]?.stringValue
        )
    }

    var stringValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}
