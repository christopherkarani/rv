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
        let fallbackSessionID = SessionID(validating: fileURL.deletingPathExtension().lastPathComponent)
        var events: [ExtractedEvent] = []

        for line in ScanJSONLEngine.byteLines(in: data) {
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
        fallbackSessionID: SessionID?
    ) -> [ExtractedEvent] {
        guard let root = ScanJSONLEngine.parseObject(line) else {
            return []
        }

        let occurredAt = root["timestamp"]?.string.flatMap(ScanTimestamp.iso8601)
        let envelopeCwd = ScanStoreWorkingDirectory.fromEnvelope(root)
        let sessionID = ScanJSONLEngine.sessionID(keys: ["sessionId"], in: root) ?? fallbackSessionID

        guard let message = root["message"], message.asObject != nil else { return [] }
        guard let content = message["content"]?.asArray else { return [] }
        let blocks = content.filter { $0.asObject != nil }

        var out: [ExtractedEvent] = []
        for block in blocks {
            guard let type = block["type"]?.string, type == "tool_use" else { continue }
            guard let name = block["name"]?.string, shellToolNames.contains(name) else { continue }
            guard let input = block["input"], input.asObject != nil else { continue }
            guard let command = input["command"]?.string, command.isEmpty == false else { continue }
            out.append(
                ExtractedEvent(
                    host: host,
                    sessionID: sessionID,
                    sourcePath: sourcePath,
                    occurredAt: occurredAt,
                    command: ShellCommand(rawValue: command),
                    workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(input) ?? envelopeCwd
                )
            )
        }
        return out
    }
}
