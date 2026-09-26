import Foundation
import RVDomain

/// Line splitting, fail-closed gates, session lookup, and the shared
/// fail-closed extraction loop for the JSONL session-store adapters.
///
/// The per-host command shapes stay in the adapter files: hooking them into
/// one descriptor would need a closure per host plus single-consumer knobs
/// for Pi's cross-line session state and Grok's layout-derived cwd, which is
/// the report's documented fallback (keep per-host adapters, share the
/// JSONL/timestamp/cwd cores). Untyped JSON survives only inside this engine
/// and the per-host matchers it calls.
enum ScanJSONLEngine {
    /// LF byte-split (Claude semantics): each line parses independently, so
    /// one non-UTF-8 line never poisons the rest. Empty segments are skipped;
    /// whitespace-only lines are left for the JSON parse to reject.
    static func byteLines(in data: Data) -> [Data] {
        guard data.isEmpty == false else { return [] }
        var out: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let next = data[offset...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[offset..<next]
            offset = next == data.endIndex ? data.endIndex : data.index(after: next)
            if line.isEmpty { continue }
            out.append(Data(line))
        }
        return out
    }

    /// Newline-split with a whole-file UTF-8 gate (Codex/Cursor/Grok/Pi
    /// semantics). Nil when `data` is not UTF-8; blank lines are skipped.
    static func textLines(in data: Data) -> [Data]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false else { return nil }
            return Data(trimmed.utf8)
        }
    }

    /// Parse one line as a JSON object. Malformed lines and JSON scalars
    /// yield nil and contribute zero events.
    static func parseObject(_ line: Data) -> [String: Any]? {
        JSONParse.object(line)
    }

    /// First valid session id for `keys` in order. Missing keys and
    /// invalid (empty) values are skipped.
    static func sessionID(keys: [String], in object: [String: Any]) -> SessionID? {
        for key in keys {
            if let value = object[key] as? String, let id = SessionID(validating: value) {
                return id
            }
        }
        return nil
    }

    /// Session lookup that also descends into `recurse` sub-objects
    /// (Codex `payload` chains).
    static func sessionIDDeep(keys: [String], recurse: [String], in object: [String: Any]) -> SessionID? {
        if let id = sessionID(keys: keys, in: object) {
            return id
        }
        for key in recurse {
            if let nested = object[key] as? [String: Any],
               let id = sessionIDDeep(keys: keys, recurse: recurse, in: nested)
            {
                return id
            }
        }
        return nil
    }

    /// Fail-closed JSONL loop shared by Codex and Cursor. Empty, non-UTF-8,
    /// or JSON-less input throws `unreadable`; otherwise each parsed object
    /// maps through the host's `commands` matcher and assembles with shared
    /// session, timestamp, and envelope-cwd rules.
    static func extractFailClosed(
        host: ScanHostID,
        data: Data,
        sourcePath: String,
        fallbackSession: SessionID?,
        sessionKeys: [String],
        recurseSessionKeys: [String] = [],
        timestampKeys: [String],
        allowEpochTimestamp: Bool,
        commands: ([String: Any]) -> [String]
    ) throws -> [ExtractedEvent] {
        guard data.isEmpty == false else {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }
        guard let lines = textLines(in: data) else {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }
        var events: [ExtractedEvent] = []
        var sawJSON = false
        for line in lines {
            guard let object = parseObject(line) else { continue }
            sawJSON = true
            let session = sessionIDDeep(keys: sessionKeys, recurse: recurseSessionKeys, in: object)
                ?? fallbackSession
            let occurredAt = ScanTimestamp.coerce(
                ScanTimestamp.firstValue(keys: timestampKeys, in: object),
                allowEpoch: allowEpochTimestamp
            )
            for command in commands(object) {
                events.append(
                    ExtractedEvent(
                        host: host,
                        sessionID: session,
                        sourcePath: sourcePath,
                        occurredAt: occurredAt,
                        command: ShellCommand(rawValue: command),
                        workingDirectory: ScanStoreWorkingDirectory.fromEnvelope(object)
                    )
                )
            }
        }
        if sawJSON == false {
            throw ScanStoreError.unreadable(sourcePath: sourcePath)
        }
        return events
    }
}
