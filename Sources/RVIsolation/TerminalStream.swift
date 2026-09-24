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

    /// `nextSequence` assigns an identity when a stored chunk is no longer the
    /// bytes originally published under `sequence`. A later subscriber must not
    /// stitch that suffix onto the full chunk by reusing the old sequence.
    mutating func append(sequence: Int64, bytes: Data, limit: Int, nextSequence: inout Int64) {
        guard bytes.isEmpty == false, limit > 0 else { return }
        var incoming = bytes
        var storedSequence = sequence
        if incoming.count > limit {
            incoming = Data(incoming.suffix(limit))
            storedSequence = allocateSequence(&nextSequence)
        }
        chunks.append(TerminalStoredChunk(sequence: storedSequence, bytes: incoming))
        byteCount += incoming.count
        var splitOldest = false
        while byteCount > limit, chunks.isEmpty == false {
            let excess = byteCount - limit
            if chunks[0].bytes.count <= excess {
                let removed = chunks.removeFirst()
                byteCount -= removed.bytes.count
            } else {
                chunks[0].bytes.removeFirst(excess)
                byteCount -= excess
                splitOldest = true
            }
        }
        if splitOldest {
            // The suffix is not the chunk that was published. Numbering only
            // that suffix uses the next sequence, which is higher than the
            // later chunks that still carry their original sequences, so a
            // late subscriber sees the suffix before the bytes that follow
            // it. Renumber the retained buffer in byte order. Live output
            // notices already used the sequences they were published with.
            for index in chunks.indices {
                chunks[index].sequence = allocateSequence(&nextSequence)
            }
        }
    }

    private func allocateSequence(_ nextSequence: inout Int64) -> Int64 {
        let assigned = nextSequence
        if nextSequence < Int64.max {
            nextSequence += 1
        }
        return assigned
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

/// Bytes already read from the PTY master.
enum TerminalMasterRead: Equatable, Sendable {
    case data
    case interrupted
    case wouldBlock
    case end
}

/// `EINTR` still has unread bytes. `EAGAIN` after a nonblocking read does not.
func terminalDrainShouldContinue(_ read: TerminalMasterRead) -> Bool {
    switch read {
    case .data, .interrupted:
        return true
    case .wouldBlock, .end:
        return false
    }
}

/// A dead session leader is claimed only when the queued handshake begins
/// with the post-exec nonce. A short prefix or unrelated bytes do not.
func deadLeaderClaimedByHandshake(queued: Data, nonce: Data) -> Bool {
    nonce.isEmpty == false && queued.count >= nonce.count && queued.starts(with: nonce)
}

enum TerminalWriteOutcome: Equatable, Sendable {
    case flushed
    case failed
    case prefixCommitted
}

/// A hard error after a short write has already committed that prefix.
func terminalWriteOutcome(written: Int, hardFailure: Bool) -> TerminalWriteOutcome {
    if hardFailure == false { return .flushed }
    if written > 0 { return .prefixCommitted }
    return .failed
}

enum TerminalClientAdmit: Equatable, Sendable {
    case accept(queued: Int)
    case overflow
}

/// Bytes still charged while a taken batch is inside `emit`.
func releaseInflight(queued: Int, inflight: Int) -> Int {
    max(0, queued - inflight)
}

enum ClientTerminalFramePlan: Equatable, Sendable {
    case store(queued: Int)
    case overflow
}

/// A frame that does not fit becomes one overflow notice. Weight 0 still fits.
func planClientTerminalFrame(queued: Int, incoming: Int, limit: Int) -> ClientTerminalFramePlan {
    switch admitClientTerminalBytes(queued: queued, incoming: incoming, limit: limit) {
    case .accept(let sum):
        return .store(queued: sum)
    case .overflow:
        return .overflow
    }
}

/// The client keeps at most one replay plus one subscriber queue. The frame
/// that does not fit is an overflow, not a dropped stream failure.
func admitClientTerminalBytes(queued: Int, incoming: Int, limit: Int) -> TerminalClientAdmit {
    guard incoming >= 0, limit > 0, queued >= 0 else { return .overflow }
    let (sum, overflowed) = queued.addingReportingOverflow(incoming)
    if overflowed || sum > limit { return .overflow }
    return .accept(queued: sum)
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
