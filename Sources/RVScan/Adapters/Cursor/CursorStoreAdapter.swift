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

    private static let profile = ScanJSONLProfile(sessionKeys: ["conversation_id", "session_id", "sessionId"], timestampKeys: ["timestamp", "ts"], allowEpochTimestamp: false, commands: Self.commands(in:))

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
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try ScanJSONLEngine.extractFailClosed(
            host: host,
            data: data,
            sourcePath: fileURL.path,
            fallbackSession: SessionID(validating: fileURL.deletingPathExtension().lastPathComponent),
            profile: Self.profile
        )
    }

    private static func commands(in object: [String: Any]) -> [String] {
        if let command = hookCommand(in: object) {
            return [command]
        }
        return []
    }

    private static func hookCommand(in object: [String: Any]) -> String? {
        let event = (object["hook_event_name"] as? String) ?? (object["hookEventName"] as? String)
        if event == "beforeShellExecution" || event == nil {
            if let command = object["command"] as? String, command.isEmpty == false {
                return command
            }
        }
        if event == nil || event == "preToolUse" || event == "PreToolUse" {
            let name = (object["tool_name"] as? String) ?? (object["toolName"] as? String)
            guard let name, shellTools.contains(name) else { return nil }
            return commandText(in: object["tool_input"] ?? object["toolInput"])
        }
        return nil
    }

    private static func commandText(in value: Any?) -> String? {
        if let object = value as? [String: Any] {
            if let command = object["command"] as? String, command.isEmpty == false {
                return command
            }
            return nil
        }
        if let text = value as? String, text.isEmpty == false {
            return text
        }
        return nil
    }
}
