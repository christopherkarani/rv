/// The pool's timing and sizing constants (docs/architecture/judge-pool.md
/// has the evidence behind each).
public struct PoolPolicy: Sendable, Equatable {
    /// Compute units of the worker that gets every request first.
    public var primaryCompute: WorkerCompute
    /// Compute units of the worker that covers the primary.
    public var hedgeCompute: WorkerCompute
    /// Send the request to the other worker too when the first has not
    /// answered by then. Above the primary's p99 on a loaded machine.
    public var hedgeAfter: Duration
    /// A request that finds the primary busy (but healthy) waits this long
    /// for it before going to the hedge: about one primary p95, so a burst
    /// does not land on the slower hedge at once.
    public var primaryBusyWait: Duration
    /// The most a request waits for an answer, and the most a worker may
    /// spend on one prediction before it is SIGKILLed (the only way to
    /// cancel a Core ML prediction).
    public var budget: Duration
    /// Requests waiting for a worker. One more is refused at once (busy).
    public var queueLimit: Int
    /// Respawn delay after a fault: base doubling per consecutive fault,
    /// capped; reset when a worker loads.
    public var backoffBase: Duration
    public var backoffCap: Duration
    /// A worker with `faultsToDegrade` faults (crash, overrun kill, load
    /// timeout) inside `faultWindow` is degraded: not spawned, not routed
    /// to, for `degradeCooldown`.
    public var faultWindow: Duration
    public var faultsToDegrade: Int
    public var degradeCooldown: Duration
    /// A worker that has not finished loading by then is killed (a fault).
    public var loadTimeout: Duration
    /// After a worker reports the bundle unloadable, retry no sooner than
    /// this (the in-process loader cached a failure for a minute too).
    public var loadFailureRetry: Duration
    /// After the model key changes, another change is refused for this
    /// long: a client alternating keys cannot keep both workers reloading.
    public var keyChangeInterval: Duration

    public init(
        primaryCompute: WorkerCompute = .cpu,
        hedgeCompute: WorkerCompute = .accelerated,
        hedgeAfter: Duration = .milliseconds(150),
        primaryBusyWait: Duration = .milliseconds(40),
        budget: Duration = .milliseconds(1500),
        queueLimit: Int = 8,
        backoffBase: Duration = .milliseconds(250),
        backoffCap: Duration = .seconds(30),
        faultWindow: Duration = .seconds(300),
        faultsToDegrade: Int = 3,
        degradeCooldown: Duration = .seconds(600),
        loadTimeout: Duration = .seconds(180),
        loadFailureRetry: Duration = .seconds(60),
        keyChangeInterval: Duration = .seconds(10)
    ) {
        precondition(queueLimit > 0 && faultsToDegrade > 0)
        self.primaryCompute = primaryCompute
        self.hedgeCompute = hedgeCompute
        self.hedgeAfter = hedgeAfter
        self.primaryBusyWait = primaryBusyWait
        self.budget = budget
        self.queueLimit = queueLimit
        self.backoffBase = backoffBase
        self.backoffCap = backoffCap
        self.faultWindow = faultWindow
        self.faultsToDegrade = faultsToDegrade
        self.degradeCooldown = degradeCooldown
        self.loadTimeout = loadTimeout
        self.loadFailureRetry = loadFailureRetry
        self.keyChangeInterval = keyChangeInterval
    }

    public static let live = PoolPolicy()

    public func compute(for slot: WorkerSlot) -> WorkerCompute {
        switch slot {
        case .primary: primaryCompute
        case .hedge: hedgeCompute
        }
    }

    func backoff(step: Int) -> Duration {
        var delay = backoffBase
        for _ in 0..<min(step, 16) {
            delay = delay * 2
            if delay >= backoffCap { return backoffCap }
        }
        return min(delay, backoffCap)
    }
}
