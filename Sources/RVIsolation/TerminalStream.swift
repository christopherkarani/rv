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
        // Cheap pre-filter sized from `maximum`: base64 of a within-maximum
        // payload never exceeds this bound while `maximum` is within the
        // supported input size, so it rejects only inputs the decoded
        // check below would reject anyway. Inputs beyond
        // `maximumInputBytes` were never supported (the old fixed 5464
        // guard rejected them too); the cap keeps that limit instead of
        // overflowing the multiplication. The decoded-length check below
        // is authoritative.
        let encodedBound: Int
        if maximum >= TerminalStreamLimits.maximumInputBytes {
            encodedBound = TerminalStreamLimits.maximumEncodedBytes
        } else {
            encodedBound = ((maximum + 2) / 3) * 4
        }
        guard text.utf8.count <= encodedBound else { return nil }
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

#if os(macOS)

// MARK: - Terminal control-plane dispatch (T2 seam)

/// One terminal control-plane command. The server translates each terminal
/// wire op into exactly one of these; the supervisor interprets it against
/// the deep RuntimeTerminal implementation. Each terminal operation is
/// defined once: its shape here, its meaning in the dispatch.
enum TerminalControlCommand {
    case subscribe(emit: @Sendable (TerminalNotice) -> Bool, windowNotices: Bool, replayBatches: Bool)
    case activate
    case unsubscribe
    case acquire
    case release
    case write(bytes: Data)
    case resize(rows: Int, columns: Int)
}

/// Outcome of one terminal dispatch. Subscribe reports the live window for
/// its reply; every other command reports completion.
enum TerminalControlResult: Sendable, Equatable {
    case subscribed(rows: Int?, columns: Int?)
    case done

    /// Live window from a subscribe outcome; nil for any other outcome.
    var window: (rows: Int?, columns: Int?) {
        if case .subscribed(let rows, let columns) = self {
            return (rows, columns)
        }
        return (nil, nil)
    }
}

// MARK: - Terminal stream codec (T2 seam)

/// One owned home for the terminal frame/notice mapping. The server emits
/// through `encode` and the client queue parses through `decode`; the two
/// directions sit adjacent so a frame-shape change updates both together.
/// The queue below (`EventBoard`) and the host reader (`RuntimeTerminal`)
/// are the two queue mechanisms speaking this one protocol.
enum TerminalStreamCodec {
    /// Server-side emit: one host notice becomes one wire frame.
    static func encode(_ notice: TerminalNotice, runtime: UUID) -> WorkspaceControlResponse {
        switch notice {
        case .replayBegin(let batch, let truncated, let byteCount):
            WorkspaceControlResponse(
                operation: .terminalReplayBegin,
                runtime: runtime,
                ok: true,
                batch: batch,
                truncated: truncated,
                replayLength: byteCount
            )
        case .replay(let sequence, let bytes):
            WorkspaceControlResponse(
                operation: .terminalReplay,
                runtime: runtime,
                ok: true,
                sequence: sequence,
                bytes: TerminalBytesCodec.encode(bytes)
            )
        case .replayEnd(let batch):
            WorkspaceControlResponse(
                operation: .terminalReplayEnd,
                runtime: runtime,
                ok: true,
                batch: batch
            )
        case .output(let sequence, let bytes):
            WorkspaceControlResponse(
                operation: .terminalOutput,
                runtime: runtime,
                ok: true,
                sequence: sequence,
                bytes: TerminalBytesCodec.encode(bytes)
            )
        case .inputOwner(let owned):
            WorkspaceControlResponse(
                operation: .terminalInputOwner,
                runtime: runtime,
                ok: true,
                inputOwner: owned
            )
        case .window(let rows, let columns):
            WorkspaceControlResponse(
                operation: .terminalWindow,
                runtime: runtime,
                ok: true,
                rows: rows,
                columns: columns
            )
        case .exited(let status):
            WorkspaceControlResponse(
                operation: .runtimeExited,
                runtime: runtime,
                ok: true,
                running: false,
                exitStatus: status
            )
        case .overflow:
            WorkspaceControlResponse(
                operation: .terminalOverflow,
                runtime: runtime,
                ok: true
            )
        }
    }

    /// Client-side parse: one wire frame becomes one terminal event, or nil
    /// when the frame carries no terminal event.
    static func decode(_ message: WorkspaceControlResponse) -> WorkspaceTerminalEvent? {
        guard let runtime = message.runtime, let operation = message.operation else { return nil }
        switch operation {
        case .terminalReplayBegin:
            guard let batch = message.batch, let truncated = message.truncated,
                let byteCount = message.replayLength
            else { return nil }
            return WorkspaceTerminalEvent(
                runtime: runtime,
                body: .replayBegin(batch: batch, truncated: truncated, byteCount: byteCount)
            )
        case .terminalReplay:
            guard let sequence = message.sequence, let bytes = message.bytes,
                let data = TerminalBytesCodec.decode(bytes, maximum: TerminalStreamLimits.readChunkBytes)
            else { return nil }
            return WorkspaceTerminalEvent(runtime: runtime, body: .replay(sequence: sequence, bytes: data))
        case .terminalReplayEnd:
            guard let batch = message.batch else { return nil }
            return WorkspaceTerminalEvent(runtime: runtime, body: .replayEnd(batch: batch))
        case .terminalOutput:
            guard let sequence = message.sequence, let bytes = message.bytes,
                let data = TerminalBytesCodec.decode(bytes, maximum: TerminalStreamLimits.readChunkBytes)
            else { return nil }
            return WorkspaceTerminalEvent(runtime: runtime, body: .output(sequence: sequence, bytes: data))
        case .terminalInputOwner:
            guard let owned = message.inputOwner else { return nil }
            return WorkspaceTerminalEvent(runtime: runtime, body: .inputOwner(owned))
        case .terminalWindow:
            guard let rows = message.rows, let columns = message.columns,
                TerminalStreamLimits.accepts(rows: rows, columns: columns)
            else { return nil }
            return WorkspaceTerminalEvent(runtime: runtime, body: .window(rows: rows, columns: columns))
        case .runtimeExited:
            guard let status = message.exitStatus else { return nil }
            return WorkspaceTerminalEvent(runtime: runtime, body: .exited(status))
        case .terminalOverflow:
            return WorkspaceTerminalEvent(runtime: runtime, body: .overflow)
        default:
            return nil
        }
    }
}


// MARK: - Terminal client queue (T2 seam)

// NSCondition is load-bearing: `next(timeout:)` waits on a multi-predicate
// queue (messages/failed) with broadcast wakeups, and the client API is
// synchronous. Mutex has no condition wait; an async rewrite is out of scope.
final class EventBoard: @unchecked Sendable {
    /// One replay plus one live queue across all subscribed runtimes.
    static let queueLimit = TerminalStreamLimits.replayBytes + TerminalStreamLimits.subscriberQueueBytes
    static let runtimeLimit = TerminalStreamLimits.subscriberQueueBytes
    /// Leave room for one owner, overflow, and exit notice per host runtime.
    /// A healthy PTY can emit hundreds of short frames before its consumer
    /// wakes. The byte cap still bounds bulk output; reserve 320 slots for
    /// replay begin/end, owner, overflow, and exit notices across the
    /// 64-runtime envelope (five control notices per runtime).
    static let outputFrameLimit = 704
    /// Tiny output frames and control notices must not grow without bound.
    static let frameLimit = 1_024

    static func payloadBytes(_ message: WorkspaceControlResponse) -> Int {
        guard let encoded = message.bytes else { return 0 }
        guard let data = TerminalBytesCodec.decode(
            encoded,
            maximum: TerminalStreamLimits.readChunkBytes
        ) else {
            return queueLimit + 1
        }
        return data.count
    }

    private let condition = NSCondition()
    private var streaming = false
    private var readerClaimed = false
    private var failed: WorkspaceClientFailure?
    private var waiters: [UUID: ReplyWaiter] = [:]
    private var messages: [WorkspaceControlResponse] = []
    private var queuedBytes = 0
    private var runtimeBytes: [UUID: Int] = [:]
    private var overflowed: Set<UUID> = []
    private var replayBatches: [UUID: (id: UUID, remaining: Int)] = [:]
    /// False when the host predates replay-batch framing: unframed replay
    /// content is admitted as plain output instead of failing the batch.
    /// Strict by default; `connect` sets it from negotiated features.
    /// Written under the condition lock (read by the event reader thread).
    var supportsReplayBatches = true

    /// Records the negotiated replay-framing support. Lock-guarded: the
    /// event reader consults the flag on every replay frame.
    func setSupportsReplayBatches(_ value: Bool) {
        condition.lock()
        supportsReplayBatches = value
        condition.unlock()
    }
    private var lastServedRuntime: UUID?

    var queuedTerminalBytes: Int {
        condition.lock()
        let value = queuedBytes
        condition.unlock()
        return value
    }

    var queuedTerminalFrames: Int {
        condition.lock()
        let value = messages.count
        condition.unlock()
        return value
    }

    func queuedTerminalBytes(for runtime: UUID) -> Int {
        condition.lock()
        let value = runtimeBytes[runtime] ?? 0
        condition.unlock()
        return value
    }

    func hasOverflowNotice(for runtime: UUID) -> Bool {
        condition.lock()
        let value = messages.contains {
            $0.runtime == runtime && $0.rawOperation == WorkspaceControlOp.terminalOverflow.rawValue
        }
        condition.unlock()
        return value
    }

    var isStreaming: Bool {
        condition.lock()
        let value = streaming
        condition.unlock()
        return value
    }

    var failure: WorkspaceClientFailure? {
        condition.lock()
        let value = failed
        condition.unlock()
        return value
    }

    func armStreaming() {
        condition.lock()
        streaming = true
        condition.unlock()
    }

    func claimReader() -> Bool {
        condition.lock()
        if readerClaimed {
            condition.unlock()
            return false
        }
        readerClaimed = true
        condition.unlock()
        return true
    }

    func register(_ id: UUID, waiter: ReplyWaiter) -> Bool {
        condition.lock()
        if streaming == false || failed != nil {
            condition.unlock()
            return false
        }
        waiters[id] = waiter
        condition.unlock()
        return true
    }

    func fail(_ id: UUID, _ error: WorkspaceClientFailure) {
        condition.lock()
        let waiter = waiters.removeValue(forKey: id)
        condition.unlock()
        waiter?.fail(error)
    }

    /// A new subscription starts a fresh replay epoch. Drop any bytes or
    /// overflow notice from the previous subscription before its reply arrives.
    func resetRuntime(_ runtime: UUID) {
        condition.lock()
        messages.removeAll { $0.runtime == runtime }
        queuedBytes -= runtimeBytes.removeValue(forKey: runtime) ?? 0
        overflowed.remove(runtime)
        replayBatches.removeValue(forKey: runtime)
        condition.unlock()
    }

    /// Clears only the swallow-output mark, keeping queued frames and replay
    /// tracking intact. Every (re)subscribe calls this before its RPC so a
    /// previously poisoned board admits the fresh replay and live output.
    /// Safe on healthy subscriptions: their queued backlog is untouched and
    /// an in-flight replay batch keeps its exact accounting.
    func clearOverflowed(_ runtime: UUID) {
        condition.lock()
        overflowed.remove(runtime)
        condition.unlock()
    }

    /// False when the frame is neither a matching reply nor a terminal event.
    func deliver(_ message: WorkspaceControlResponse) -> Bool {
        condition.lock()
        guard failed == nil else {
            condition.unlock()
            return false
        }
        if let id = message.id, let waiter = waiters.removeValue(forKey: id) {
            condition.unlock()
            waiter.succeed(message)
            return true
        }
        if message.rawOperation == WorkspaceControlOp.workspaceClosed.rawValue {
            condition.unlock()
            return true
        }
        guard TerminalStreamCodec.decode(message) != nil, let runtime = message.runtime else {
            condition.unlock()
            return false
        }
        let accepted: Bool
        var invalidBatch = false
        switch message.rawOperation {
        case WorkspaceControlOp.terminalReplayBegin.rawValue:
            // Once a runtime overflows, its batch is incomplete. Ignore any
            // remaining boundaries until a new subscription resets its queue.
            if overflowed.contains(runtime) {
                accepted = true
            } else if let batch = message.batch, let byteCount = message.replayLength,
                replayBatches[runtime] == nil
            {
                accepted = messages.count < EventBoard.frameLimit
                if accepted {
                    replayBatches[runtime] = (batch, byteCount)
                    messages.append(message)
                }
            } else {
                invalidBatch = true
                accepted = false
            }
        case WorkspaceControlOp.terminalReplay.rawValue:
            if overflowed.contains(runtime) {
                accepted = true
            } else if supportsReplayBatches == false {
                // Legacy host: replay content arrives unframed. Admit it as
                // plain output; there is no batch to validate against.
                accepted = admitOutput(message, runtime: runtime)
            } else if var batch = replayBatches[runtime] {
                let weight = EventBoard.payloadBytes(message)
                if weight > 0, weight <= batch.remaining {
                    batch.remaining -= weight
                    replayBatches[runtime] = batch
                    accepted = admitOutput(message, runtime: runtime)
                } else {
                    invalidBatch = true
                    accepted = false
                }
            } else {
                invalidBatch = true
                accepted = false
            }
        case WorkspaceControlOp.terminalReplayEnd.rawValue:
            if overflowed.contains(runtime) {
                accepted = true
            } else if let batch = replayBatches[runtime], batch.id == message.batch,
                batch.remaining == 0
            {
                accepted = messages.count < EventBoard.frameLimit
                if accepted {
                    replayBatches.removeValue(forKey: runtime)
                    messages.append(message)
                }
            } else {
                invalidBatch = true
                accepted = false
            }
        case WorkspaceControlOp.terminalOutput.rawValue:
            invalidBatch = replayBatches[runtime] != nil
            accepted = replayBatches[runtime] == nil && admitOutput(message, runtime: runtime)
        case WorkspaceControlOp.terminalOverflow.rawValue:
            accepted = markOverflow(runtime)
        case WorkspaceControlOp.terminalInputOwner.rawValue:
            // Only the latest occupancy state is useful to an attached view.
            messages.removeAll {
                $0.runtime == runtime && $0.rawOperation == WorkspaceControlOp.terminalInputOwner.rawValue
            }
            accepted = messages.count < EventBoard.frameLimit
            if accepted { messages.append(message) }
        case WorkspaceControlOp.terminalWindow.rawValue:
            // Only the latest actual dimensions are useful to an attached view.
            messages.removeAll {
                $0.runtime == runtime && $0.rawOperation == WorkspaceControlOp.terminalWindow.rawValue
            }
            accepted = messages.count < EventBoard.frameLimit
            if accepted { messages.append(message) }
        case WorkspaceControlOp.runtimeExited.rawValue:
            if messages.contains(where: {
                $0.runtime == runtime && $0.rawOperation == WorkspaceControlOp.runtimeExited.rawValue
            }) == false {
                accepted = messages.count < EventBoard.frameLimit
                if accepted { messages.append(message) }
            } else {
                accepted = true
            }
        default:
            condition.unlock()
            return false
        }
        guard accepted else {
            if invalidBatch, markOverflow(runtime) {
                // One runtime sent an out-of-order replay frame. Drop only
                // its incomplete output; every other runtime's queued bytes
                // and all pending RPC waiters stay intact.
                condition.broadcast()
                condition.unlock()
                return true
            }
            condition.unlock()
            failAll(.queueOverloaded)
            return false
        }
        condition.broadcast()
        condition.unlock()
        return true
    }

    private static func isOutput(_ message: WorkspaceControlResponse) -> Bool {
        message.rawOperation == WorkspaceControlOp.terminalReplay.rawValue
            || message.rawOperation == WorkspaceControlOp.terminalOutput.rawValue
    }

    /// Reserve room for the first output from a different runtime by dropping
    /// the largest queued stream and attributing that loss to its source.
    private func admitOutput(_ message: WorkspaceControlResponse, runtime: UUID) -> Bool {
        if overflowed.contains(runtime) { return true }
        let weight = EventBoard.payloadBytes(message)
        guard weight > 0, weight <= EventBoard.runtimeLimit else {
            return markOverflow(runtime)
        }
        let runtimeTotal = (runtimeBytes[runtime] ?? 0).addingReportingOverflow(weight)
        guard runtimeTotal.overflow == false,
            runtimeTotal.partialValue <= EventBoard.runtimeLimit
        else {
            return markOverflow(runtime)
        }
        if canQueueOutput(weight: weight) == false, runtimeBytes[runtime] == nil {
            while canQueueOutput(weight: weight) == false,
                let victim = largestQueuedOutput(excluding: runtime)
            {
                guard markOverflow(victim) else { return false }
            }
        }
        guard canQueueOutput(weight: weight) else { return markOverflow(runtime) }
        messages.append(message)
        runtimeBytes[runtime] = runtimeTotal.partialValue
        queuedBytes += weight
        return true
    }

    private func canQueueOutput(weight: Int) -> Bool {
        let total = queuedBytes.addingReportingOverflow(weight)
        return total.overflow == false
            && total.partialValue <= EventBoard.queueLimit
            && messages.filter({ EventBoard.isOutput($0) }).count < EventBoard.outputFrameLimit
            && messages.count < EventBoard.frameLimit
    }

    private func largestQueuedOutput(excluding newcomer: UUID) -> UUID? {
        var frames: [UUID: Int] = [:]
        for message in messages where EventBoard.isOutput(message) {
            if let runtime = message.runtime, runtime != newcomer {
                frames[runtime, default: 0] += 1
            }
        }
        return frames.keys.sorted { first, second in
            let firstBytes = runtimeBytes[first] ?? 0
            let secondBytes = runtimeBytes[second] ?? 0
            if firstBytes != secondBytes { return firstBytes > secondBytes }
            if frames[first] != frames[second] { return frames[first, default: 0] > frames[second, default: 0] }
            return first.uuidString < second.uuidString
        }.first
    }

    /// Lose only this runtime's incomplete output. Its exit/owner events and
    /// every other runtime's queued bytes remain available to the UI.
    private func markOverflow(_ runtime: UUID) -> Bool {
        messages.removeAll { message in
            guard message.runtime == runtime else { return false }
            return EventBoard.isOutput(message)
                || message.rawOperation == WorkspaceControlOp.terminalReplayBegin.rawValue
                || message.rawOperation == WorkspaceControlOp.terminalReplayEnd.rawValue
        }
        queuedBytes -= runtimeBytes.removeValue(forKey: runtime) ?? 0
        replayBatches.removeValue(forKey: runtime)
        if overflowed.contains(runtime) { return true }
        guard messages.count < EventBoard.frameLimit else { return false }
        overflowed.insert(runtime)
        messages.append(
            WorkspaceControlResponse(
                operation: .terminalOverflow,
                runtime: runtime,
                ok: true
            )
        )
        return true
    }

    func failAll(_ error: WorkspaceClientFailure) {
        condition.lock()
        if failed == nil { failed = error }
        let pending = waiters
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for waiter in pending.values {
            waiter.fail(error)
        }
    }

    func next(timeout: TimeInterval) -> Result<WorkspaceControlResponse?, WorkspaceClientFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while messages.isEmpty, failed == nil {
            if condition.wait(until: deadline) == false, messages.isEmpty, failed == nil {
                condition.unlock()
                return .success(nil)
            }
        }
        if let failed, failed == .queueOverloaded || failed == .malformed {
            condition.unlock()
            return .failure(failed)
        }
        if messages.isEmpty, let failed {
            condition.unlock()
            return .failure(failed)
        }
        let index = nextIndex()
        let message = messages.remove(at: index)
        lastServedRuntime = message.runtime
        // Only output frames ever increment the byte budget (via
        // `admitOutput`); a control notice carrying bytes must not refund
        // bytes it never charged.
        let weight = EventBoard.isOutput(message) ? EventBoard.payloadBytes(message) : 0
        queuedBytes = max(0, queuedBytes - weight)
        if let runtime = message.runtime, weight > 0 {
            let remainder = (runtimeBytes[runtime] ?? 0) - weight
            runtimeBytes[runtime] = remainder > 0 ? remainder : nil
        }
        condition.unlock()
        return .success(message)
    }

    /// Choose a runtime with a pending exit first, but drain its own earlier
    /// bytes before the exit. Otherwise rotate between runtime heads.
    private func nextIndex() -> Int {
        var heads: [Int] = []
        var seen: Set<UUID> = []
        let exiting = Set(messages.compactMap { message -> UUID? in
            message.rawOperation == WorkspaceControlOp.runtimeExited.rawValue ? message.runtime : nil
        })
        for index in messages.indices {
            guard let runtime = messages[index].runtime, seen.insert(runtime).inserted else {
                continue
            }
            heads.append(index)
        }
        let preferred = heads.filter { index in
            messages[index].runtime.map(exiting.contains) == true
        }
        let candidates = preferred.isEmpty ? heads : preferred
        return candidates.first { messages[$0].runtime != lastServedRuntime }
            ?? candidates.first
            ?? 0
    }
}

#endif
