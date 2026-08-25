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

    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        let sourcePath = fileURL.path
        let sessionID = fileURL.deletingLastPathComponent().lastPathComponent
        var events: [ExtractedEvent] = []

        for line in Self.jsonlLines(in: data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let toolCalls = object["tool_calls"] as? [[String: Any]]
            else {
                continue
            }
            for call in toolCalls {
                guard let name = call["name"] as? String,
                      Self.shellTools.contains(name),
                      let command = Self.command(fromArguments: call["arguments"]),
                      command.isEmpty == false
                else {
                    continue
                }
                events.append(
                    ExtractedEvent(
                        host: .grok,
                        sessionID: sessionID.isEmpty ? nil : sessionID,
                        sourcePath: sourcePath,
                        occurredAt: nil,
                        command: ShellCommand(rawValue: command)
                    )
                )
            }
        }
        return events
    }

    private static func command(fromArguments value: Any?) -> String? {
        if let object = value as? [String: Any] {
            return object["command"] as? String
        }
        guard let raw = value as? String,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["command"] as? String
    }

    private static func jsonlLines(in data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false else { return nil }
            return Data(trimmed.utf8)
        }
    }
}
