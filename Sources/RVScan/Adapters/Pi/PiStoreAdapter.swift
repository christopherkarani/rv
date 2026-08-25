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

    public func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent] {
        let sourcePath = fileURL.path
        var sessionID: String?
        var events: [ExtractedEvent] = []

        for line in Self.jsonlLines(in: data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            let type = object["type"] as? String
            if type == "session", let id = object["id"] as? String, id.isEmpty == false {
                sessionID = id
            }
            guard type == "message",
                  let message = object["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let content = message["content"] as? [[String: Any]]
            else {
                continue
            }
            let occurredAt = Self.date(from: object["timestamp"])
                ?? Self.date(from: message["timestamp"])
            for item in content {
                guard (item["type"] as? String) == "toolCall",
                      (item["name"] as? String) == "bash",
                      let arguments = item["arguments"] as? [String: Any],
                      let command = arguments["command"] as? String,
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
                        command: ShellCommand(rawValue: command)
                    )
                )
            }
        }
        return events
    }

    private static func jsonlLines(in data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false else { return nil }
            return Data(trimmed.utf8)
        }
    }

    private static func date(from value: Any?) -> Date? {
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            return basic.date(from: string)
        }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            return Date(timeIntervalSince1970: raw)
        }
        return nil
    }
}
