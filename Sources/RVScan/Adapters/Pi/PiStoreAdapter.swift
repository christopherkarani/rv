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
        var sessionID: SessionID?
        var sessionCwd: WorkingDirectory?
        var events: [ExtractedEvent] = []

        guard let lines = ScanJSONLEngine.textLines(in: data) else { return [] }
        for line in lines {
            guard let object = ScanJSONLEngine.parseObject(line) else {
                continue
            }
            let type = object["type"] as? String
            if type == "session" {
                if let id = object["id"] as? String, let parsed = SessionID(validating: id) {
                    sessionID = parsed
                }
                if let cwd = ScanStoreWorkingDirectory.fromEnvelope(object) {
                    sessionCwd = cwd
                }
            }
            guard type == "message",
                  let message = object["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let content = message["content"] as? [[String: Any]]
            else {
                continue
            }
            let occurredAt = ScanTimestamp.coerce(object["timestamp"], allowEpoch: true, requirePositive: false)
                ?? ScanTimestamp.coerce(message["timestamp"], allowEpoch: true, requirePositive: false)
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
                        command: ShellCommand(rawValue: command),
                        workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(arguments)
                            ?? ScanStoreWorkingDirectory.fromEnvelope(item)
                            ?? sessionCwd
                    )
                )
            }
        }
        return events
    }
}
