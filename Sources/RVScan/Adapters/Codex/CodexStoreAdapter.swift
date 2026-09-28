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
        if let payload = object["payload"] as? [String: Any] {
            return commands(in: payload)
        }
        if let command = functionCallCommand(in: object) {
            return [command]
        }
        return []
    }

    private static func hookCommand(in object: [String: Any]) -> String? {
        let event = (object["hook_event_name"] as? String) ?? (object["hookEventName"] as? String)
        guard event == nil || event == "PreToolUse" else { return nil }
        let name = (object["tool_name"] as? String) ?? (object["toolName"] as? String)
        guard let name, shellTools.contains(name) else { return nil }
        return commandText(in: object["tool_input"] ?? object["toolInput"])
    }

    private static func functionCallCommand(in object: [String: Any]) -> String? {
        let type = object["type"] as? String
        if type == "function_call" || type == "tool_use" {
            let name = (object["name"] as? String) ?? (object["toolName"] as? String)
            guard let name, shellTools.contains(name) else { return nil }
            return commandText(in: object["arguments"] ?? object["input"] ?? object["tool_input"])
        }
        if type == "exec_command_begin" || type == "exec_command" {
            return commandText(in: object["command"])
        }
        return nil
    }

    private static func commandText(in value: Any?) -> String? {
        if let object = value as? [String: Any] {
            if let command = object["command"] as? String, command.isEmpty == false {
                return command
            }
            if let parts = object["command"] as? [Any] {
                return commandText(in: parts)
            }
            return nil
        }
        if let parts = value as? [Any] {
            let tokens = parts.compactMap { $0 as? String }.filter { $0.isEmpty == false }
            return tokens.isEmpty ? nil : tokens.joined(separator: " ")
        }
        if let text = value as? String, text.isEmpty == false {
            if let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                return commandText(in: parsed)
            }
            return text
        }
        return nil
    }
}
