import Foundation
import RVDomain

/// One surface-extracted shell candidate plus provenance.
public struct ExtractedEvent: Sendable, Equatable {
    public var host: ScanHostID
    public var sessionID: String?
    public var sourcePath: String
    public var occurredAt: Date?
    public var command: ShellCommand
    /// Session-store cwd when the layout or envelope already recorded one.
    /// Nil means classify stays unprobed. Never process.cwd.
    public var workingDirectory: WorkingDirectory? = nil

    public init(
        host: ScanHostID,
        sessionID: String? = nil,
        sourcePath: String,
        occurredAt: Date? = nil,
        command: ShellCommand,
        workingDirectory: WorkingDirectory? = nil
    ) {
        self.host = host
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.occurredAt = occurredAt
        self.command = command
        self.workingDirectory = workingDirectory
    }
}

/// Discovers host session roots, recognizes layout files, and surface-extracts events.
public protocol SessionStoreAdapter: Sendable {
    var host: ScanHostID { get }
    func roots(home: ScanHome) -> [URL]
    func recognizes(fileURL: URL) -> Bool
    /// Map recognized store bytes to surface events. `fileURL` is provenance;
    /// `data` is the store.
    func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent]
}

/// Cwd already present in a session store. Lexical only — no `FileManager`,
/// no `process.cwd`, no live symlink follow.
enum ScanStoreWorkingDirectory {
    /// Hook-codec field names: `cwd`, `workdir`, `working_directory`.
    static func fromEnvelope(_ object: [String: Any], depth: Int = 0) -> WorkingDirectory? {
        guard depth < 6 else { return nil }
        if let direct = fromFields(object) {
            return direct
        }
        let nestedKeys = [
            "params", "args", "toolInput", "tool_input", "input",
            "arguments", "state", "payload", "function",
        ]
        for key in nestedKeys {
            if let nested = object[key] as? [String: Any],
               let found = fromEnvelope(nested, depth: depth + 1)
            {
                return found
            }
            if let found = fromJSONString(object[key], depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// `$HOME/.grok/sessions/<cwd>/<session-id>/chat_history.jsonl`.
    /// Recover only a parseable absolute filesystem path. Relative slugs stay nil.
    static func fromGrokLayout(fileURL: URL) -> WorkingDirectory? {
        let path = fileURL.path
        let marker = "/.grok/sessions/"
        guard let range = path.range(of: marker) else { return nil }
        let remainder = String(path[range.upperBound...])
        var parts = remainder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" {
            parts.removeLast()
        }
        guard parts.count >= 3 else { return nil }
        let cwdParts = Array(parts.dropLast(2))
        return parseableAbsolutePath(cwdParts)
    }

    private static func fromFields(_ object: [String: Any]) -> WorkingDirectory? {
        for key in ["cwd", "workdir", "workingDirectory", "working_directory"] {
            if let raw = object[key] as? String, raw.isEmpty == false {
                return WorkingDirectory(validating: raw)
            }
        }
        return nil
    }

    private static func fromJSONString(_ value: Any?, depth: Int) -> WorkingDirectory? {
        guard let raw = value as? String, raw.isEmpty == false,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return fromEnvelope(object, depth: depth)
    }

    private static func parseableAbsolutePath(_ parts: [String]) -> WorkingDirectory? {
        guard parts.isEmpty == false else { return nil }
        let decoded = parts.map { $0.removingPercentEncoding ?? $0 }
        let joined: String
        if decoded.count == 1 {
            joined = decoded[0]
        } else if decoded[0].isEmpty {
            joined = "/" + decoded.dropFirst().joined(separator: "/")
        } else if decoded[0].hasPrefix("/") {
            joined = decoded.joined(separator: "/")
        } else {
            return nil
        }
        guard joined.hasPrefix("/") else { return nil }
        return WorkingDirectory(validating: joined)
    }
}
