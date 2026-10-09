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

    /// Surface-extract shell `tool_calls` rows from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    public func extract(fileURL: URL, data: Data) throws(ScanStoreError) -> [ExtractedEvent] {
        let sourcePath = fileURL.path
        let sessionID = fileURL.deletingLastPathComponent().lastPathComponent
        let workingDirectory = ScanStoreWorkingDirectory.fromGrokLayout(fileURL: fileURL)
        var events: [ExtractedEvent] = []

        guard data.isEmpty == false else {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }
        guard let lines = ScanJSONLEngine.textLines(in: data) else {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }
        var sawJSON = false
        for line in lines {
            guard let object = ScanJSONLEngine.parseObject(line) else {
                continue
            }
            sawJSON = true
            guard object["type"]?.string == "assistant",
                  let toolCalls = object["tool_calls"]?.asArray,
                  toolCalls.allSatisfy({ $0.asObject != nil })
            else {
                continue
            }
            for call in toolCalls {
                guard let name = call["name"]?.string,
                      Self.shellTools.contains(name),
                      let command = Self.command(fromArguments: call["arguments"]),
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
        guard sawJSON else {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }
        return events
    }

    private static func command(fromArguments value: JSONValue?) -> String? {
        if value?.asObject != nil {
            return value?["command"]?.string
        }
        guard let raw = value?.string,
              let object = JSONParse.object(raw)
        else {
            return nil
        }
        return object["command"]?.string
    }
}
