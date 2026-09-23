import Foundation

/// Bounds for one host-owned terminal stream.
///
/// PTY bytes are not text. Callers carry them as base64 inside the existing
/// `rv.workspace.v1` frame so a second socket is unnecessary. The host reads
/// the PTY master once and fans those bytes out. History is a bounded replay
/// buffer, not a scrollback file.
///
/// A workspace-host crash closes the PTY with the host. Crash recovery still
/// reclaims the recorded process group. This stream does not resume across
/// that process death. Detach of a client does not close the master.
public enum TerminalStreamLimits {
    public static let minimumDimension = 1
    public static let maximumRows = 512
    public static let maximumColumns = 512
    public static let defaultRows = 24
    public static let defaultColumns = 80
    /// One authoritative read from the PTY master.
    public static let readChunkBytes = 4_096
    /// In-memory history retained for a later attach. Older bytes are dropped.
    public static let replayBytes = 65_536
    /// Bytes queued for one subscriber before that subscriber is dropped.
    public static let subscriberQueueBytes = 65_536
    public static let maximumInputBytes = 4_096
    public static let maximumSubscribers = 8
    /// Base64 length of `maximumInputBytes`, including padding.
    public static let maximumEncodedBytes = 5_464
    /// Explicit terminal type for interactive runtimes. The host environment
    /// is not copied. Other variables stay the sanitized launch set:
    /// `PATH`, `LANG`, `LC_ALL`, `HOME`, and `TMPDIR`.
    public static let supportedTerm = "xterm-256color"

    public static func accepts(rows: Int, columns: Int) -> Bool {
        (minimumDimension...maximumRows).contains(rows)
            && (minimumDimension...maximumColumns).contains(columns)
    }
}

struct TerminalStoredChunk: Equatable, Sendable {
    var sequence: Int64
    var bytes: Data
}

/// Oldest chunks fall out once `limit` bytes are exceeded.
struct TerminalReplayBuffer: Equatable, Sendable {
    private(set) var chunks: [TerminalStoredChunk] = []
    private(set) var byteCount = 0

    mutating func append(sequence: Int64, bytes: Data, limit: Int) {
        guard bytes.isEmpty == false, limit > 0 else { return }
        var incoming = bytes
        if incoming.count > limit {
            incoming = Data(incoming.suffix(limit))
        }
        chunks.append(TerminalStoredChunk(sequence: sequence, bytes: incoming))
        byteCount += incoming.count
        while byteCount > limit, chunks.isEmpty == false {
            let excess = byteCount - limit
            if chunks[0].bytes.count <= excess {
                let removed = chunks.removeFirst()
                byteCount -= removed.bytes.count
            } else {
                chunks[0].bytes.removeFirst(excess)
                byteCount -= excess
            }
        }
    }
}

enum TerminalQueueDecision: Equatable, Sendable {
    case queued(bytes: Int)
    case overflow
}

enum TerminalQueue {
    static func decide(queued: Int, incoming: Int, limit: Int) -> TerminalQueueDecision {
        guard incoming > 0, limit > 0, queued >= 0 else { return .overflow }
        let (sum, overflow) = queued.addingReportingOverflow(incoming)
        if overflow || sum > limit { return .overflow }
        return .queued(bytes: sum)
    }
}

enum TerminalBytesCodec {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func decode(_ text: String, maximum: Int) -> Data? {
        guard text.utf8.count <= TerminalStreamLimits.maximumEncodedBytes else { return nil }
        guard text.isEmpty || text.utf8.allSatisfy(isBase64Character) else { return nil }
        guard let data = Data(base64Encoded: text), data.count <= maximum else { return nil }
        return data
    }

    private static func isBase64Character(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "+"),
            UInt8(ascii: "/"),
            UInt8(ascii: "="):
            return true
        default:
            return false
        }
    }
}
