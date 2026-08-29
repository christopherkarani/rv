import Foundation
import RVDomain

/// Fail-closed Cursor store I/O. Empty or non-UTF-8 bytes are an error,
/// not a successful empty event list.
public enum CursorStoreError: Error, Sendable, Equatable {
    /// `data` is empty, not UTF-8, or wholly unreadable as JSONL.
    case unreadable(sourcePath: String)
}

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
    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        try Self.events(
            in: data,
            sourcePath: fileURL.path,
            fallbackSession: Self.sessionID(from: fileURL)
        )
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
            throw CursorStoreError.unreadable(sourcePath: sourcePath)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CursorStoreError.unreadable(sourcePath: sourcePath)
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
                        host: .cursor,
                        sessionID: sessionID(in: object) ?? fallbackSession,
                        sourcePath: sourcePath,
                        occurredAt: parseTimestamp(object["timestamp"] ?? object["ts"]),
                        command: ShellCommand(rawValue: command)
                    )
                )
            }
        }
        if sawJSON == false {
            throw CursorStoreError.unreadable(sourcePath: sourcePath)
        }
        return events
    }

    private static func sessionID(in object: [String: Any]) -> String? {
        if let value = object["conversation_id"] as? String, value.isEmpty == false { return value }
        if let value = object["session_id"] as? String, value.isEmpty == false { return value }
        if let value = object["sessionId"] as? String, value.isEmpty == false { return value }
        return nil
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

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let raw = value as? String, raw.isEmpty == false {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }
        return nil
    }
}
