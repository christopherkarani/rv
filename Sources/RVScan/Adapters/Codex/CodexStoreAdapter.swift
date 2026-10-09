import Foundation
import RVDomain

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

    private static let profile = ScanJSONLProfile(
        sessionKeys: ["session_id", "sessionId"],
        recurseSessionKeys: ["payload"],
        timestampKeys: ["timestamp", "ts"],
        allowEpochTimestamp: true,
        commands: Self.commands(in:)
    )

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
    public func extract(fileURL: URL, data: Data) throws(ScanStoreError) -> [ExtractedEvent] {
        try ScanJSONLEngine.extractFailClosed(
            host: host,
            data: data,
            sourcePath: fileURL.path,
            fallbackSession: SessionID(validating: fileURL.deletingPathExtension().lastPathComponent),
            profile: Self.profile
        )
    }

    private static func commands(in value: JSONValue) -> [String] {
        if let command = hookCommand(in: value) {
            return [command]
        }
        if let payload = value["payload"], payload.asObject != nil {
            return commands(in: payload)
        }
        if let command = functionCallCommand(in: value) {
            return [command]
        }
        return []
    }

    private static func hookCommand(in value: JSONValue) -> String? {
        let event = value["hook_event_name"]?.string ?? value["hookEventName"]?.string
        guard event == nil || event == "PreToolUse" else { return nil }
        let name = value["tool_name"]?.string ?? value["toolName"]?.string
        guard let name, shellTools.contains(name) else { return nil }
        return commandText(in: value["tool_input"] ?? value["toolInput"])
    }

    private static func functionCallCommand(in value: JSONValue) -> String? {
        let type = value["type"]?.string
        if type == "function_call" || type == "tool_use" {
            let name = value["name"]?.string ?? value["toolName"]?.string
            guard let name, shellTools.contains(name) else { return nil }
            return commandText(in: value["arguments"] ?? value["input"] ?? value["tool_input"])
        }
        if type == "exec_command_begin" || type == "exec_command" {
            return commandText(in: value["command"])
        }
        return nil
    }

    private static func commandText(in value: JSONValue?) -> String? {
        if value?.asObject != nil {
            if let command = value?["command"]?.string, command.isEmpty == false {
                return command
            }
            if let parts = value?["command"]?.asArray {
                return commandText(in: .array(parts))
            }
            return nil
        }
        if let parts = value?.asArray {
            let tokens = parts.compactMap(\.string).filter { $0.isEmpty == false }
            return tokens.isEmpty ? nil : tokens.joined(separator: " ")
        }
        if let text = value?.string, text.isEmpty == false {
            // Recurse only into containers: the old `JSONSerialization`
            // funnel rejected top-level fragments, so scalar text never
            // parsed and passed through verbatim. A parsed scalar must not
            // drop the command (number/bool/null recurse to nil) or rewrite
            // it (a quoted string would unquote).
            if let parsed = JSONParse.value(text), parsed.asObject != nil || parsed.asArray != nil {
                return commandText(in: parsed)
            }
            return text
        }
        return nil
    }
}
