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
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try Self.events(in: data, sourcePath: fileURL.path, fallbackSession: Self.sessionID(from: fileURL))
    }

    private static func sessionID(from fileURL: URL) -> String? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : stem
    }

    private static func events(
        in data: Data,
        sourcePath: String,
        fallbackSession: String?
    ) throws -> [ExtractedEvent] {
        guard data.isEmpty == false else {
            throw CodexStoreError.unreadable(sourcePath: sourcePath)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexStoreError.unreadable(sourcePath: sourcePath)
        }

        var events: [ExtractedEvent] = []
        var sawJSON = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.isEmpty == false else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else {
                continue
            }
            sawJSON = true
            for command in commands(in: object) {
                events.append(
                    ExtractedEvent(
                        host: .codex,
                        sessionID: sessionID(in: object) ?? fallbackSession,
                        sourcePath: sourcePath,
                        occurredAt: parseTimestamp(object["timestamp"] ?? object["ts"]),
                        command: ShellCommand(rawValue: command)
                    )
                )
            }
        }
        if sawJSON == false {
            throw CodexStoreError.unreadable(sourcePath: sourcePath)
        }
        return events
    }

    private static func sessionID(in object: [String: Any]) -> String? {
        if let value = object["session_id"] as? String, value.isEmpty == false { return value }
        if let value = object["sessionId"] as? String, value.isEmpty == false { return value }
        if let payload = object["payload"] as? [String: Any] {
            return sessionID(in: payload)
        }
        return nil
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

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let raw = value as? String, raw.isEmpty == false {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }
        if let raw = value as? Double, raw > 0 {
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            return Date(timeIntervalSince1970: raw)
        }
        return nil
    }
}
