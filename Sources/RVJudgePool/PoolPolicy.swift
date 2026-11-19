/// The pool's timing and sizing constants (docs/architecture/judge-pool.md
/// has the evidence behind each).
public struct PoolPolicy: Sendable, Equatable {
    /// Send the request to the other worker too when the first has not
    /// answered by then. About the primary worker's p95 on a warm model.
    public var hedgeAfter: Duration
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

    public init(
        hedgeAfter: Duration = .milliseconds(450),
        budget: Duration = .milliseconds(1500),
        queueLimit: Int = 8,
        backoffBase: Duration = .milliseconds(250),
        backoffCap: Duration = .seconds(30),
        faultWindow: Duration = .seconds(300),
        faultsToDegrade: Int = 3,
        degradeCooldown: Duration = .seconds(600),
        loadTimeout: Duration = .seconds(180),
        loadFailureRetry: Duration = .seconds(60)
    ) {
        precondition(queueLimit > 0 && faultsToDegrade > 0)
        self.hedgeAfter = hedgeAfter
        self.budget = budget
        self.queueLimit = queueLimit
        self.backoffBase = backoffBase
        self.backoffCap = backoffCap
        self.faultWindow = faultWindow
        self.faultsToDegrade = faultsToDegrade
        self.degradeCooldown = degradeCooldown
        self.loadTimeout = loadTimeout
        self.loadFailureRetry = loadFailureRetry
    }

    public static let live = PoolPolicy()

    func backoff(step: Int) -> Duration {
        var delay = backoffBase
        for _ in 0..<min(step, 16) {
            delay = delay * 2
            if delay >= backoffCap { return backoffCap }
        }
        return min(delay, backoffCap)
    }
}
