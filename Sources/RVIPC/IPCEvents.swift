import Foundation
import RVDomain

// Live events from rvd (workstream I, chunk I1): decisions, asks and
// resolutions as a stream. The stream is a long poll over the existing
// unary transports (Unix socket, XPC): each `events` call returns what was
// published after the caller's cursor, or waits up to `waitMs` for the
// next event. rvd keeps one bounded ring per lifetime; a subscriber that
// falls behind it loses the oldest events and is told how many (`missed`).
// Nothing a subscriber does, or fails to do, can block a publisher.

/// `events` params. A first call passes neither `stream` nor `after`
/// (start at the live head) or `after: 0` (start at the oldest event rvd
/// still holds). Every later call passes back the reply's `stream` and
/// `cursor`.
public struct EventsParams: Sendable, Equatable, Codable {
    /// The `stream` of the reply the cursor came from. A different stream
    /// (rvd restarted) restarts the read at the oldest retained event with
    /// `resync` set.
    public var stream: UUID?
    /// Last sequence number the caller has seen. Nil: start at the head.
    public var after: UInt64?
    /// How long to wait for an event when none is ready. Nil or 0 answers
    /// at once; rvd caps it at `EventsParams.maxWaitMs`.
    public var waitMs: Int?

    /// rvd's cap on one long poll. Kept under the hook budget (7 s), so a
    /// daemon draining for a replaced binary never waits on a poll longer
    /// than it already waits on a hook.
    public static let maxWaitMs = 5_000

    public init(stream: UUID? = nil, after: UInt64? = nil, waitMs: Int? = nil) {
        self.stream = stream
        self.after = after
        self.waitMs = waitMs
    }
}

/// `events` reply: the events after the caller's cursor, oldest first.
public struct EventsReply: Sendable, Equatable, Codable {
    /// This rvd lifetime's sequence. Echo it in the next call.
    public var stream: UUID
    /// Pass as `after` in the next call: the last event's sequence number,
    /// or the read position when `events` is empty.
    public var cursor: UInt64
    /// Events dropped between the caller's cursor and the first event
    /// here, because the caller read too slowly ("missed N"). 0 when none.
    public var missed: UInt64
    /// The caller's stream is gone (rvd restarted, or the cursor was not
    /// one rvd issued): an unknown number of events may be missing, so
    /// state derived from earlier events should be reloaded
    /// (`pendingList`).
    public var resync: Bool
    public var events: [LiveEvent]

    public init(stream: UUID, cursor: UInt64, missed: UInt64 = 0, resync: Bool = false, events: [LiveEvent]) {
        self.stream = stream
        self.cursor = cursor
        self.missed = missed
        self.resync = resync
        self.events = events
    }
}

/// One published event. `atMs` is milliseconds since 1970 (no `Date`
/// crosses `rv.ipc.v1`): the evaluation start for a decision, the row's
/// time for an ask or a resolution.
public struct LiveEvent: Sendable, Equatable {
    public var sequence: UInt64
    public var atMs: Int64
    public var payload: LiveEventPayload

    public init(sequence: UInt64, atMs: Int64, payload: LiveEventPayload) {
        self.sequence = sequence
        self.atMs = atMs
        self.payload = payload
    }

    /// A time outside what `Int64` milliseconds can hold (or not a number)
    /// clamps to the nearest end (NaN to 0) instead of trapping.
    public init(sequence: UInt64, at time: Date, payload: LiveEventPayload) {
        self.init(sequence: sequence, atMs: Self.milliseconds(since1970: time.timeIntervalSince1970), payload: payload)
    }

    static func milliseconds(since1970 seconds: Double) -> Int64 {
        let ms = (seconds * 1000).rounded()
        guard ms.isNaN == false else { return 0 }
        // 2^63 as a Double; anything at or past it does not fit.
        if ms >= 9_223_372_036_854_775_808.0 { return .max }
        if ms < -9_223_372_036_854_775_808.0 { return .min }
        return Int64(ms)
    }
}

/// What happened. Open for additive kinds (F2 proposals, boxes): a reader
/// decodes a kind it does not know, or a known kind it cannot read, as
/// `.unknown`, so one new event never breaks an old client's stream.
public enum LiveEventPayload: Sendable, Equatable {
    /// A hook decision rvd replied with.
    case decision(LiveDecision)
    /// A hook ask became a pending row awaiting a human.
    case ask(LiveAsk)
    /// A pending row left awaiting-human (a human answered, it expired,
    /// or the agent's retry used the answer).
    case resolution(LiveResolution)
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .decision: "decision"
        case .ask: "ask"
        case .resolution: "resolution"
        case .unknown(let kind): kind
        }
    }
}

extension LiveEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case atMs
        case kind
        case decision
        case ask
        case resolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        atMs = try container.decode(Int64.self, forKey: .atMs)
        let kind = try container.decode(String.self, forKey: .kind)
        // A body that fails to decode is an unknown event, not a broken
        // reply: the sequence still advances the reader's cursor.
        switch kind {
        case "decision":
            payload = (try? container.decode(LiveDecision.self, forKey: .decision)).map { .decision($0) }
                ?? .unknown(kind: kind)
        case "ask":
            payload = (try? container.decode(LiveAsk.self, forKey: .ask)).map { .ask($0) }
                ?? .unknown(kind: kind)
        case "resolution":
            payload = (try? container.decode(LiveResolution.self, forKey: .resolution)).map { .resolution($0) }
                ?? .unknown(kind: kind)
        default:
            payload = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(atMs, forKey: .atMs)
        try container.encode(payload.kind, forKey: .kind)
        switch payload {
        case .decision(let decision):
            try container.encode(decision, forKey: .decision)
        case .ask(let ask):
            try container.encode(ask, forKey: .ask)
        case .resolution(let resolution):
            try container.encode(resolution, forKey: .resolution)
        case .unknown:
            break
        }
    }
}

/// The reply an agent's hook got, as the agent saw it.
public enum LiveVerdict: String, Sendable, Equatable, Codable {
    case allowed
    case denied
    /// Indeterminate, or rvd ran past its budget (`timedOut`).
    case refused
}

/// The tool a decision was about (the blocks ledger's tool names).
public enum LiveTool: String, Sendable, Equatable, Codable {
    case bash = "Bash"
    case read = "Read"
    case edit = "Edit"
    case write = "Write"
}

/// One hook decision. Redacted the way rvd's local records are: no
/// credential-shaped tokens, `$HOME` shown as `~`, control characters
/// flattened, text capped (`maxTextBytes`). Shell decisions carry
/// `command`; file decisions carry `path`.
public struct LiveDecision: Sendable, Equatable, Codable {
    /// Longest `command` or `path`, in UTF-8 bytes, before the ellipsis.
    public static let maxTextBytes = 512

    public var verdict: LiveVerdict
    public var host: HookHost
    public var tool: LiveTool
    public var command: String?
    public var path: String?
    public var cwd: String?
    /// Rule id as the blocks ledger writes it (`core.git:reset-hard`),
    /// `rv.indeterminate:<reason>`, or `rv.timeout`. Nil on an allow.
    public var rule: String?
    /// The host's session id, only when it is an opaque token.
    public var session: String?
    /// rvd ran past its budget and replied with its timeout deny,
    /// whatever the evaluation found (`verdict` is then `refused`).
    public var timedOut: Bool

    public init(
        verdict: LiveVerdict, host: HookHost, tool: LiveTool, command: String? = nil, path: String? = nil,
        cwd: String? = nil, rule: String? = nil, session: String? = nil, timedOut: Bool = false
    ) {
        self.verdict = verdict
        self.host = host
        self.tool = tool
        self.command = command
        self.path = path
        self.cwd = cwd
        self.rule = rule
        self.session = session
        self.timedOut = timedOut
    }
}

/// A new pending row: the same projection `pendingList` returns (no
/// command text).
public struct LiveAsk: Sendable, Equatable, Codable {
    public var item: PendingListItem

    public init(item: PendingListItem) {
        self.item = item
    }
}

/// How a pending row left awaiting-human.
public enum LiveResolutionOutcome: String, Sendable, Equatable, Codable {
    case allowOnce
    case createRule
    case deny
    case expired
    case canceled
    case timedOut
    /// The agent's retry used the answer.
    case consumed
}

public struct LiveResolution: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var host: HookHost
    public var outcome: LiveResolutionOutcome

    public init(id: ApprovalID, host: HookHost, outcome: LiveResolutionOutcome) {
        self.id = id
        self.host = host
        self.outcome = outcome
    }
}

public struct EventsCall: IPCCall {
    public var params: EventsParams
    public var method: IPCMethod { .events(params) }

    public init(params: EventsParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> EventsReply? {
        if case .events(let reply) = result { return reply }
        return nil
    }

    /// True when the answering rvd predates `events`: it cannot decode the
    /// method key and answers `decodeFailed` (`unknownMethod` from a build
    /// that decodes it but refuses it). The caller keeps polling what it
    /// polled before (`pendingWatch`) instead of treating it as a failure.
    public static func isUnsupported(_ result: IPCResult) -> Bool {
        switch result {
        case .error(.decodeFailed), .error(.unknownMethod): true
        default: false
        }
    }
}
