import Foundation
import RVDomain

/// Grok session store under `$HOME/.grok/sessions/<cwd>/<session-id>/chat_history.jsonl`.
/// Surface field: assistant `tool_calls[]` with shell tool names and JSON-string
/// `arguments` containing `command` (see Grok user-guide session layout).
public struct GrokStoreAdapter: SessionStoreAdapter {
    public var host: ScanHostID { .grok }

    private static let shellTools: Set<String> = [
        "run_terminal_command",
        "run_terminal_cmd",
        "Bash",
    ]

    public init() {}

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".grok/sessions", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        fileURL.lastPathComponent == "chat_history.jsonl"
    }

    /// Surface-extract shell tool-call events from provided store bytes.
    ///
    /// Per-file failure policy (best-effort, unchanged): never throws —
    /// undecodable data, bad lines, and unknown shapes contribute zero events.
    public func extract(fileURL: URL, data: Data) throws(SessionStoreError) -> [ExtractedEvent] {
        let sourcePath = fileURL.path
        let sessionID = fileURL.deletingLastPathComponent().lastPathComponent
        let workingDirectory = ScanStoreWorkingDirectory.fromGrokLayout(fileURL: fileURL)
        var events: [ExtractedEvent] = []

        for line in ScanJSONLines.lines(from: data) {
            guard let storeLine = ScanJSONLines.decode(GrokStoreLine.self, from: line),
                  storeLine.type == "assistant",
                  let toolCalls = storeLine.toolCalls
            else {
                continue
            }
            for call in toolCalls {
                guard let name = call.name,
                      Self.shellTools.contains(name),
                      let command = Self.command(fromArguments: call.arguments),
                      command.isEmpty == false
                else {
                    continue
                }
                events.append(
                    ExtractedEvent(
                        host: .grok,
                        sessionID: SessionID(validating: sessionID),
                        sourcePath: sourcePath,
                        occurredAt: nil,
                        command: ShellCommand(rawValue: command),
                        workingDirectory: workingDirectory
                    )
                )
            }
        }
        return events
    }

    /// Old `command(fromArguments:)`: an object yields its string `command`; a
    /// string is re-parsed as JSON and yields the object's string `command`;
    /// anything else yields nil.
    private static func command(fromArguments value: GrokArguments?) -> String? {
        switch value {
        case .object(let input):
            return input.command
        case .text(let raw):
            guard let payload = raw.data(using: .utf8),
                  let input = try? JSONDecoder().decode(GrokArgumentsObject.self, from: payload)
            else {
                return nil
            }
            return input.command
        case .other, nil:
            return nil
        }
    }
}

/// One JSONL line of the Grok session store. Covers exactly the fields
/// extraction reads: the entry type and assistant tool calls.
///
/// Lenient: every field decodes with `try?`, so any JSON object yields a line
/// and only non-object lines fail to decode — the typed equivalent of the old
/// `as? [String: Any]` line check. Explicit JSON null decodes as absent.
private struct GrokStoreLine: Decodable {
    var type: String?
    var toolCalls: [GrokToolCall]?

    enum CodingKeys: String, CodingKey {
        case type
        case toolCalls = "tool_calls"
    }

    /// Field-independent leniency: a present-but-wrong-typed scalar decodes
    /// as nil (matching the old per-field `as?`) instead of failing the line.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        toolCalls = try? container.decode([GrokToolCall].self, forKey: .toolCalls)
    }
}

/// One assistant tool call: the tool name plus its arguments carrier.
/// Lenient: any JSON object decodes; wrong-typed fields become nil. A
/// non-object element still fails the enclosing `tool_calls` array, matching
/// the old `as? [[String: Any]]` line check.
private struct GrokToolCall: Decodable {
    var name: String?
    var arguments: GrokArguments?

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        arguments = try? container.decode(GrokArguments.self, forKey: .arguments)
    }
}

/// A tool-call arguments carrier: JSON-encoded string, object, or inert.
/// Total: every JSON value decodes (numbers/bools/null/arrays become `.other`),
/// so a wrong-typed `arguments` skips only its call, never the line.
private enum GrokArguments: Decodable {
    case text(String)
    case object(GrokArgumentsObject)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        if let value = try? container.decode(GrokArgumentsObject.self) {
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
        if (try? container.decode([GrokInertJSON].self)) != nil {
            self = .other
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }
}

/// A tool-call arguments object: the string `command`.
/// Lenient: any JSON object decodes; a wrong-typed `command` becomes nil.
private struct GrokArgumentsObject: Decodable {
    var command: String?

    enum CodingKeys: String, CodingKey {
        case command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try? container.decode(String.self, forKey: .command)
    }
}

/// Total consumer for array payloads, which carry no command.
private struct GrokInertJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([GrokInertJSON].self)) != nil { return }
        if (try? container.decode([String: GrokInertJSON].self)) != nil { return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }
}
