import Foundation

/// The Laya judge worker pool's wire vocabulary (docs/architecture/judge-pool.md).
///
/// The pool is model-agnostic: it never imports Core ML or RVLaya. A worker's
/// verdict travels as opaque JSON bytes from the worker to the client, which
/// decodes and validates it; the supervisor only routes.
public enum JudgePoolWire {
    /// launchd label and Mach service of the supervisor (`rv-judge serve`).
    public static let machServiceName = "dev.rv.judge"
    /// Bumped on any incompatible change to the client or worker messages.
    /// A client and supervisor that disagree never exchange a judge request.
    public static let protocolVersion = 2
    /// XPC dictionary key holding one JSON message body.
    public static let xpcDataKey = "body"
    /// XPC dictionary key holding the anonymous request endpoint.
    public static let xpcEndpointKey = "endpoint"
    /// A client's allowance over the pool budget for delivery both ways.
    public static let transportSlack: Duration = .milliseconds(250)
}

/// The two workers, named by role. `primary` gets every request first;
/// `hedge` gets a request the primary has not answered by `hedgeAfter`, or
/// one the primary is too busy, down or degraded to take. Which compute
/// units each runs is `PoolPolicy.primaryCompute` / `hedgeCompute`.
public enum WorkerSlot: String, Sendable, Codable, CaseIterable, Hashable {
    case primary
    case hedge

    var other: WorkerSlot {
        switch self {
        case .primary: .hedge
        case .hedge: .primary
        }
    }
}

/// The Core ML compute units a worker loads with: `--compute` on its argv.
/// `cpu` is `.cpuOnly` and never enters the MPSGraph path that has aborted
/// the judge; `accelerated` is `.cpuAndGPU`.
public enum WorkerCompute: String, Sendable, Codable, CaseIterable, Hashable {
    case cpu
    case accelerated
}

/// Which model the workers load: the engine (`ft` | `laya`) and its bundle
/// directory. Workers are bound to one key; a request for another key
/// restarts them.
public struct ModelKey: Sendable, Codable, Hashable {
    public let engine: String
    public let bundle: String

    public init(engine: String, bundle: String) {
        self.engine = engine
        self.bundle = bundle
    }

    /// Only the two shipped engines and an absolute, NUL-free bundle path.
    /// Anything else is refused before it reaches a worker's argv.
    public var isWellFormed: Bool {
        ["ft", "laya"].contains(engine)
            && bundle.hasPrefix("/") && !bundle.contains("\0") && bundle.utf8.count <= 4096
    }
}

/// Exactly what `FineTunedJudge.judge(_:contextLines:)` takes. The stock
/// engine ignores `contextLines`.
public struct JudgeInput: Sendable, Codable, Equatable {
    public let command: String
    public let contextLines: [String]

    public init(command: String, contextLines: [String]) {
        self.command = command
        self.contextLines = contextLines
    }
}

/// Why no worker could load the bundle. Mirrors `LayaError.badBundle` /
/// `.modelUnavailable` (a broken install or an invalid private cache).
/// rvd maps it to a failed judge run, so judged calls go to review; doctor
/// shows the cause.
public struct LoadFailure: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case badBundle
        case modelUnavailable
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// The pool's answer to one judge request. Only `verdict` carries a score;
/// every other case is a judge that could not score this request, which the
/// client maps to the gate's fail-closed outcomes (review), `loadFailed`
/// (broken install, doctor-visible) included.
public enum PoolOutcome: Sendable, Codable, Equatable {
    /// JSON of the worker's `LayaVerdict`, and which worker produced it.
    case verdict(Data, slot: WorkerSlot)
    /// Queue full: refused without running.
    case busy
    /// Dispatched, but no worker answered within the budget.
    case late
    /// No worker was ready to take it within the budget.
    case warming
    /// Every worker failed to load the bundle.
    case loadFailed(LoadFailure)
    /// Prediction failed on every worker that ran it, or every worker is
    /// crash-looping.
    case failed(String)
}

/// Supervisor → worker: one prediction. A worker runs one at a time.
public struct WorkerRequest: Sendable, Codable, Equatable {
    public let id: String
    public let input: JudgeInput

    public init(id: String, input: JudgeInput) {
        self.id = id
        self.input = input
    }
}

/// Worker → supervisor.
public enum WorkerEvent: Sendable, Codable, Equatable {
    /// The worker's Core ML guard has started: crash recovery has read the
    /// previous generation's in-flight marker, so a marker left from here on
    /// is this worker's own. Sent once, before the load. The supervisor
    /// consumes it (`PoolCore` never sees it).
    case guardStarted
    /// The model loaded; the worker takes requests.
    case ready(checkpoint: String)
    /// The model did not load. The worker exits after sending it.
    case loadFailed(LoadFailure)
    /// One prediction's verdict (JSON of `LayaVerdict`).
    case verdict(id: String, verdict: Data)
    /// One prediction threw.
    case failed(id: String)
}

/// Client → supervisor (XPC).
public enum JudgePoolRequest: Sendable, Codable, Equatable {
    case hello(protocolVersion: Int)
    /// `budgetMilliseconds` is the most the client will wait; the pool
    /// answers within min(budget, its own budget).
    case judge(key: ModelKey, input: JudgeInput, budgetMilliseconds: Int)
    /// Load this key's model now, so the first judged request does not pay
    /// the load.
    case warm(key: ModelKey)
    case status
}

/// Supervisor → client (XPC).
public enum JudgePoolReply: Sendable, Codable, Equatable {
    case helloAck(protocolVersion: Int)
    case outcome(PoolOutcome)
    case ack
    case status(PoolStatus)
    /// The peer is not an authorized client, skipped the handshake, or sent
    /// something malformed. Carries no detail.
    case refused
}

/// What doctor reports about the pool.
public struct PoolStatus: Sendable, Codable, Equatable {
    public struct Worker: Sendable, Codable, Equatable {
        public let slot: WorkerSlot
        public let compute: String
        /// down | loading | ready | busy | stopping
        public let phase: String
        public let restarts: Int
        public let recentFaults: Int
        public let degraded: Bool
        public let loadFailure: LoadFailure?

        public init(
            slot: WorkerSlot, compute: String, phase: String, restarts: Int,
            recentFaults: Int, degraded: Bool, loadFailure: LoadFailure?
        ) {
            self.slot = slot
            self.compute = compute
            self.phase = phase
            self.restarts = restarts
            self.recentFaults = recentFaults
            self.degraded = degraded
            self.loadFailure = loadFailure
        }
    }

    public let protocolVersion: Int
    public let engine: String?
    public let workers: [Worker]
    public let queued: Int
    public let served: Int
    public let hedged: Int
    public let hedgeWins: Int
    public let killed: Int
    public let late: Int
    public let refusedBusy: Int

    public init(
        protocolVersion: Int, engine: String?, workers: [Worker], queued: Int, served: Int,
        hedged: Int, hedgeWins: Int, killed: Int, late: Int, refusedBusy: Int
    ) {
        self.protocolVersion = protocolVersion
        self.engine = engine
        self.workers = workers
        self.queued = queued
        self.served = served
        self.hedged = hedged
        self.hedgeWins = hedgeWins
        self.killed = killed
        self.late = late
        self.refusedBusy = refusedBusy
    }

    /// Everything routes to `hedge` while `primary` is degraded.
    public var routing: String {
        let degraded = Set(workers.filter(\.degraded).map(\.slot))
        switch (degraded.contains(.primary), degraded.contains(.hedge)) {
        case (false, false): return "hedged"
        case (true, false): return "hedge only (primary degraded)"
        case (false, true): return "unhedged (hedge degraded)"
        case (true, true): return "none (both workers degraded)"
        }
    }
}

/// The judge as rvd sees it: one synchronous call per judged command.
/// `nil` means the pool could not be reached or could not be verified
/// before the deadline. Callers map nil to review, never to allow.
public protocol JudgeClient: Sendable {
    func judge(key: ModelKey, input: JudgeInput, budget: Duration) -> PoolOutcome?
    /// Best effort; never blocks the caller for long.
    func warm(key: ModelKey)
    func status(timeout: Duration) -> PoolStatus?
}

/// JSON helpers shared by every end of the pool.
public enum JudgePoolJSON {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

extension Duration {
    /// Whole milliseconds, rounded down, never negative.
    var wholeMilliseconds: Int {
        let parts = components
        let millis = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
        return Int(max(0, millis))
    }
}
