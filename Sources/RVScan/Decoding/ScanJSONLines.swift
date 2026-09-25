import Foundation

/// Lenient JSONL splitting + per-line decoding for session-store adapters.
///
/// Best-effort: unknown shapes and bad lines contribute zero events and never
/// abort extraction. Per-host schemas keep every property optional so a
/// missing field decodes as nil instead of failing the line.
enum ScanJSONLines {
    /// Splits `data` on LF. Empty lines and invalid-UTF-8 lines are skipped
    /// (best-effort); every returned line is non-empty valid UTF-8.
    static func lines(from data: Data) -> [Data] {
        guard data.isEmpty == false else { return [] }
        var out: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let next = data[offset...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let slice = data[offset..<next]
            offset = next == data.endIndex ? data.endIndex : data.index(after: next)
            guard slice.isEmpty == false else { continue }
            let line = Data(slice)
            guard String(data: line, encoding: .utf8) != nil else { continue }
            out.append(line)
        }
        return out
    }

    /// Decodes one line leniently; nil when undecodable or wrong shape.
    static func decode<Line: Decodable>(_ type: Line.Type, from line: Data) -> Line? {
        try? JSONDecoder().decode(type, from: line)
    }
}
