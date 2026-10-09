import Foundation
import RVDomain

/// Best-effort `ScanHostID.claude` JSONL session-store adapter (surface fields only).
///
/// Layout: `$HOME/.claude/projects/<slug>/**/*.jsonl`. Extract walks assistant
/// `tool_use` blocks whose `name` is a shell tool and reads `input.command`.
/// Unknown shapes and bad lines contribute zero events, but empty or
/// JSON-less `data` throws `ScanStoreError.unreadable`; unrecognized files
/// still yield no events.
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

    /// Surface-extract shell `tool_use` blocks from provided store bytes.
    /// `fileURL` is provenance only; missing or unreadable `data` throws.
    public func extract(fileURL: URL, data: Data) throws(ScanStoreError) -> [ExtractedEvent] {
        guard recognizes(fileURL: fileURL) else { return [] }
        guard data.isEmpty == false else {
            throw ScanStoreError.unreadable(sourcePath: fileURL.path)
        }

        let sourcePath = fileURL.path
        let fallbackSessionID = SessionID(validating: fileURL.deletingPathExtension().lastPathComponent)
        var events: [ExtractedEvent] = []
        var sawJSON = false

        for line in ScanJSONLEngine.byteLines(in: data) {
            guard let root = ScanJSONLEngine.parseObject(line) else {
                continue
            }
            sawJSON = true
            events.append(
                contentsOf: Self.events(
                    fromRoot: root,
                    host: host,
                    sourcePath: sourcePath,
                    fallbackSessionID: fallbackSessionID
                )
            )
        }
        guard sawJSON else {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }

        return events
    }

    private static func events(
        fromRoot root: JSONValue,
        host: ScanHostID,
        sourcePath: String,
        fallbackSessionID: SessionID?
    ) -> [ExtractedEvent] {
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
