import Foundation
import RVDomain

/// Pi session store under `$HOME/.pi/agent/sessions/**/*.jsonl`.
/// Surface field: `message.content[].type == "toolCall"` with `name == "bash"`
/// and `arguments.command` (string).
public struct PiStoreAdapter: SessionStoreAdapter {
    public var host: ScanHostID { .pi }

    public init() {}

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".pi/agent/sessions", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == "jsonl"
    }

    /// Surface-extract bash tool-call events from provided store bytes.
    ///
    /// Per-file failure policy (best-effort, unchanged): never throws —
    /// undecodable data, bad lines, and unknown shapes contribute zero events.
    /// Session id/cwd accumulate from `session` lines across the file.
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        let sourcePath = fileURL.path
        var sessionID: SessionID?
        var sessionCwd: WorkingDirectory?
        var events: [ExtractedEvent] = []

        for line in ScanJSONLines.lines(from: data) {
            guard let storeLine = ScanJSONLines.decode(PiStoreLine.self, from: line) else {
                continue
            }
            if storeLine.type == "session" {
                if let id = storeLine.id, let parsed = SessionID(validating: id) {
                    sessionID = parsed
                }
                if let cwd = storeLine.workingDirectory {
                    sessionCwd = cwd
                }
            }
            guard storeLine.type == "message",
                  let message = storeLine.message,
                  message.role == "assistant",
                  let content = message.content
            else {
                continue
            }
            let occurredAt = Self.date(from: storeLine.timestamp)
                ?? Self.date(from: message.timestamp)
            for item in content {
                guard item.type == "toolCall",
                      item.name == "bash",
                      let arguments = item.arguments,
                      let command = arguments.command,
                      command.isEmpty == false
                else {
                    continue
                }
                events.append(
                    ExtractedEvent(
                        host: .pi,
                        sessionID: sessionID,
                        sourcePath: sourcePath,
                        occurredAt: occurredAt,
                        command: ShellCommand(rawValue: command),
                        workingDirectory: arguments.workingDirectory
                            ?? item.workingDirectory
                            ?? sessionCwd
                    )
                )
            }
        }
        return events
    }

    /// Old `date(from:)`: ISO-8601 strings parse; numbers are epoch seconds
    /// (milliseconds above 1e12, with no positivity guard). A
    /// present-but-unparseable line timestamp falls through to the message
    /// timestamp. JSON booleans decode as absent (the old NSNumber crawl read
    /// `true` as epoch 1; no real store emits boolean timestamps).
    private static func date(from value: PiTimestamp?) -> Date? {
        switch value {
        case .text(let raw):
            return ScanTimestamp.parse(raw)
        case .number(let raw):
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            return Date(timeIntervalSince1970: raw)
        case .other, nil:
            return nil
        }
    }
}

/// One JSONL line of the Pi session store. Covers exactly the fields
/// extraction reads: the line type, session id, timestamps, the message, and
/// cwd-ish fields.
///
/// Lenient: every field decodes with `try?`, so any JSON object yields a line
/// and only non-object lines fail to decode — the typed equivalent of the old
/// `as? [String: Any]` line check. Explicit JSON null decodes as absent.
private struct PiStoreLine: Decodable {
    var type: String?
    var id: String?
    var timestamp: PiTimestamp?
    var message: PiStoreMessage?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Session-line cwd over the direct fields — the typed replacement for
    /// this adapter's share of the old deep crawl (which also probed unmodeled
    /// `params`/`args`/`state`/`payload` keys and JSON-string carriers below
    /// the envelope; those exotic nestings now read as absent).
    var workingDirectory: WorkingDirectory? {
        ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case timestamp
        case message
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    /// Field-independent leniency: a present-but-wrong-typed scalar decodes
    /// as nil (matching the old per-field `as?`) instead of failing the line.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        id = try? container.decode(String.self, forKey: .id)
        timestamp = try? container.decode(PiTimestamp.self, forKey: .timestamp)
        message = try? container.decode(PiStoreMessage.self, forKey: .message)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// A Pi message: the role, its timestamp, and content items.
/// Lenient: any JSON object decodes; wrong-typed fields become nil. A
/// non-object element still fails the enclosing `content` array, matching the
/// old `as? [[String: Any]]` line check.
private struct PiStoreMessage: Decodable {
    var role: String?
    var timestamp: PiTimestamp?
    var content: [PiContentItem]?

    enum CodingKeys: String, CodingKey {
        case role
        case timestamp
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try? container.decode(String.self, forKey: .role)
        timestamp = try? container.decode(PiTimestamp.self, forKey: .timestamp)
        content = try? container.decode([PiContentItem].self, forKey: .content)
    }
}

/// One message content item: tool-call routing, its arguments, and cwd-ish
/// fields. Lenient: any JSON object decodes; wrong-typed fields become nil.
private struct PiContentItem: Decodable {
    var type: String?
    var name: String?
    var arguments: PiStoreArguments?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Direct cwd-ish fields. The old crawl also probed unmodeled nested keys
    /// (`params`, `args`, `toolInput`, …) on the item; those exotic nestings
    /// now read as absent.
    var workingDirectory: WorkingDirectory? {
        ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case arguments
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        name = try? container.decode(String.self, forKey: .name)
        arguments = try? container.decode(PiStoreArguments.self, forKey: .arguments)
        cwd = try? container.decode(String.self, forKey: .cwd)
        workdir = try? container.decode(String.self, forKey: .workdir)
        workingDirectoryRaw = try? container.decode(String.self, forKey: .workingDirectoryRaw)
        workingDirectorySnake = try? container.decode(String.self, forKey: .workingDirectorySnake)
    }
}

/// Tool-call arguments: the string `command` plus cwd-ish fields.
/// Lenient: any JSON object decodes; wrong-typed fields become nil.
private struct PiStoreArguments: Decodable {
    var command: String?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    /// Direct cwd-ish fields. The old crawl also probed unmodeled nested keys
    /// and JSON-string carriers below `arguments`; those exotic nestings now
    /// read as absent.
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

/// A timestamp carrier: ISO-8601 string, epoch number, or inert.
/// Total: every JSON value decodes (bools/null/arrays/objects become `.other`),
/// so a wrong-typed `timestamp` falls through to the next timestamp source
/// instead of failing the line.
private enum PiTimestamp: Decodable {
    case text(String)
    case number(Double)
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
        if container.decodeNil() {
            self = .other
            return
        }
        if (try? container.decode(Bool.self)) != nil {
            self = .other
            return
        }
        if (try? container.decode([PiInertJSON].self)) != nil {
            self = .other
            return
        }
        if (try? container.decode([String: PiInertJSON].self)) != nil {
            self = .other
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }
}

/// Total consumer for array/object payloads, which carry no timestamp.
private struct PiInertJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([PiInertJSON].self)) != nil { return }
        if (try? container.decode([String: PiInertJSON].self)) != nil { return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }
}
