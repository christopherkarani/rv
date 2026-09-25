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
        for line in ScanJSONLines.lines(from: data) {
            guard let storeLine = ScanJSONLines.decode(ClaudeStoreLine.self, from: line) else {
                continue
            }
            events.append(
                contentsOf: Self.events(
                    from: storeLine,
                    host: host,
                    sourcePath: sourcePath,
                    fallbackSessionID: fallbackSessionID
                )
            )
        }
        return events
    }

    private static func events(
        from line: ClaudeStoreLine,
        host: ScanHostID,
        sourcePath: String,
        fallbackSessionID: SessionID?
    ) -> [ExtractedEvent] {
        let occurredAt = ScanTimestamp.parse(line.timestamp)
        let envelopeCwd = line.workingDirectory
        let sessionID: SessionID? = {
            if let value = line.sessionId {
                return SessionID(validating: value) ?? fallbackSessionID
            }
            return fallbackSessionID
        }()

        guard let blocks = line.message?.content else { return [] }
        var out: [ExtractedEvent] = []
        for block in blocks {
            guard block.type == "tool_use" else { continue }
            guard let name = block.name, shellToolNames.contains(name) else { continue }
            guard let command = block.input?.command, command.isEmpty == false else { continue }
            out.append(
                ExtractedEvent(
                    host: host,
                    sessionID: sessionID,
                    sourcePath: sourcePath,
                    occurredAt: occurredAt,
                    command: ShellCommand(rawValue: command),
                    workingDirectory: block.input?.workingDirectory ?? envelopeCwd
                )
            )
        }
        return out
    }
}

/// One JSONL line of the Claude session store. All-optional: a missing field
/// decodes as nil (best-effort) instead of failing the line. Covers exactly
/// the fields extraction reads: timestamp, session id, cwd-ish fields, and
/// the assistant message content blocks.
private struct ClaudeStoreLine: Decodable {
    var timestamp: String?
    var sessionId: String?
    var cwd: String?
    var workdir: String?
    var workingDirectory: WorkingDirectory? {
        ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?
    var message: ClaudeStoreMessage?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionId
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
        case message
    }
}

/// Assistant message. `content` is a string for text turns and an array for
/// block turns; only block turns can carry `tool_use`, so anything that is
/// not an array decodes as nil (zero events, scan continues). Non-object
/// elements inside an array are skipped, matching the previous compactMap.
private struct ClaudeStoreMessage: Decodable {
    var content: [ClaudeStoreBlock]?

    enum CodingKeys: String, CodingKey {
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? container.decode([FailableBlock].self, forKey: .content))?
            .compactMap(\.block)
    }
}

private struct ClaudeStoreBlock: Decodable {
    var type: String?
    var name: String?
    var input: ClaudeStoreInput?
}

private struct ClaudeStoreInput: Decodable {
    var command: String?
    var cwd: String?
    var workdir: String?
    var workingDirectoryRaw: String?
    var workingDirectorySnake: String?

    var workingDirectory: WorkingDirectory? {
        ScanStoreWorkingDirectory.firstValid(cwd, workdir, workingDirectoryRaw, workingDirectorySnake)
    }

    enum CodingKeys: String, CodingKey {
        case command
        case cwd
        case workdir
        case workingDirectoryRaw = "workingDirectory"
        case workingDirectorySnake = "working_directory"
    }
}

/// Per-element leniency: one malformed block never fails its siblings.
private struct FailableBlock: Decodable {
    var block: ClaudeStoreBlock?
    init(from decoder: Decoder) throws {
        block = try? ClaudeStoreBlock(from: decoder)
    }
}
