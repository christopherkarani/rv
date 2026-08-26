import Foundation
import RVDomain

/// Best-effort `ScanHostID.claude` JSONL session-store adapter (surface fields only).
///
/// Layout: `$HOME/.claude/projects/<slug>/**/*.jsonl`. Extract walks assistant
/// `tool_use` blocks whose `name` is a shell tool and reads `input.command`.
/// Unknown shapes and bad lines contribute zero events.
public struct ClaudeSessionStoreAdapter: SessionStoreAdapter {
    private static let shellToolNames: Set<String> = ["Bash", "bash", "Shell", "shell"]

    public init() {}

    public var host: ScanHostID { .claude }

    public func roots(home: ScanHome) -> [URL] {
        [home.url.appendingPathComponent(".claude/projects", isDirectory: true)]
    }

    public func recognizes(fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == "jsonl"
    }

    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        guard recognizes(fileURL: fileURL) else { return [] }

        let sourcePath = fileURL.path
        let fallbackSessionID = fileURL.deletingPathExtension().lastPathComponent
        var events: [ExtractedEvent] = []

        var offset = data.startIndex
        while offset < data.endIndex {
            let next = data[offset...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[offset..<next]
            offset = next == data.endIndex ? data.endIndex : data.index(after: next)
            if line.isEmpty { continue }
            events.append(
                contentsOf: Self.events(
                    fromLine: line,
                    host: host,
                    sourcePath: sourcePath,
                    fallbackSessionID: fallbackSessionID
                )
            )
        }

        return events
    }

    private static func events(
        fromLine line: Data,
        host: ScanHostID,
        sourcePath: String,
        fallbackSessionID: String
    ) -> [ExtractedEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return []
        }

        let occurredAt = parseTimestamp(root["timestamp"])
        let sessionID: String? = {
            if let value = root["sessionId"] as? String, value.isEmpty == false { return value }
            if fallbackSessionID.isEmpty == false { return fallbackSessionID }
            return nil
        }()

        guard let message = root["message"] as? [String: Any] else { return [] }
        let blocks: [[String: Any]]
        if let array = message["content"] as? [[String: Any]] {
            blocks = array
        } else if let array = message["content"] as? [Any] {
            blocks = array.compactMap { $0 as? [String: Any] }
        } else {
            return []
        }

        var out: [ExtractedEvent] = []
        for block in blocks {
            guard let type = block["type"] as? String, type == "tool_use" else { continue }
            guard let name = block["name"] as? String, shellToolNames.contains(name) else { continue }
            guard let input = block["input"] as? [String: Any] else { continue }
            guard let command = input["command"] as? String, command.isEmpty == false else { continue }
            out.append(
                ExtractedEvent(
                    host: host,
                    sessionID: sessionID,
                    sourcePath: sourcePath,
                    occurredAt: occurredAt,
                    command: ShellCommand(rawValue: command)
                )
            )
        }
        return out
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let raw = value as? String, raw.isEmpty == false else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
