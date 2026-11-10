import Synchronization

/// Idle-exit policy for `rvd`.
///
/// The daemon exits (launchd/systemd relaunch it on the next connect) only
/// when all of these hold:
/// - no request is in flight (listeners bracket every request with
///   `beginRequest` / `endRequest`, synchronously, before any async hop);
/// - the idle interval elapsed since the last request finished;
/// - the allow-once table holds no unexpired grant (exiting would drop the
///   human's approvals; the timer re-arms instead).
///
/// The exit decision and `beginRequest` share one lock: once exit is
/// decided, every later request is refused rather than half-served.
///
/// A replaced executable on disk overrides the idle rules: clients pin the
/// on-disk binary's code identity, so a stale daemon can serve nobody. It is
/// checked after each request and every `staleCheckInterval`; once seen, the
/// daemon stops admitting work, drains what is in flight, then exits.
public final class IdleWatchdog: Sendable {
    public static let defaultSeconds = 1800
    /// How often an idle daemon checks whether its binary was replaced.
    public static let defaultStaleCheckInterval: Duration = .seconds(5)

    private struct State {
        var phase = IdleExitPolicy.initial
        var requestCount = 0
    }

    private let state = Mutex(State())
    private let interval: Duration
    private let staleCheckInterval: Duration
    private let hasLiveGrants: @Sendable () async -> Bool
    private let executableChanged: @Sendable () -> Bool
    private let onFire: @Sendable () -> Void
    private let scheduler: IdleExitScheduler

    public convenience init(
        seconds: Int = IdleWatchdog.defaultSeconds,
        staleCheckInterval: Duration = IdleWatchdog.defaultStaleCheckInterval,
        hasLiveGrants: @escaping @Sendable () async -> Bool = { false },
        executableChanged: @escaping @Sendable () -> Bool = { false },
        onFire: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            interval: .seconds(seconds),
            staleCheckInterval: staleCheckInterval,
            hasLiveGrants: hasLiveGrants,
            executableChanged: executableChanged,
            onFire: onFire
        )
    }

    init(
        interval: Duration,
        staleCheckInterval: Duration = IdleWatchdog.defaultStaleCheckInterval,
        hasLiveGrants: @escaping @Sendable () async -> Bool = { false },
        executableChanged: @escaping @Sendable () -> Bool = { false },
        onFire: @escaping @Sendable () -> Void = {},
        scheduler: IdleExitScheduler = .dispatch(label: "rv.idle-watchdog")
    ) {
        self.scheduler = scheduler
        self.interval = interval
        self.staleCheckInterval = staleCheckInterval
        self.hasLiveGrants = hasLiveGrants
        self.executableChanged = executableChanged
        self.onFire = onFire
    }

    /// True once the exit decision was taken.
    public var hasFired: Bool { state.withLock { $0.phase == .exited } }
    var inFlight: Int {
        state.withLock {
            switch $0.phase {
            case .serving(let inFlight, _), .draining(let inFlight): inFlight
            case .exited: 0
            }
        }
    }
    var requestCount: Int { state.withLock { $0.requestCount } }

    /// Boot: arm the idle timer before the first request arrives.
    public func start() { send(.start) }

    /// Admits one request. Call synchronously on receipt, before any work.
    /// False once the daemon is exiting or draining: drop the request (the
    /// client reconnects to the relaunched daemon).
    public func beginRequest() -> Bool { send(.begin) }

    /// Ends one admitted request, after its reply was handed to the transport.
    public func endRequest() {
        send(.end(stale: executableChanged()))
    }

    /// Applies `event` under the lock, then runs the effects outside it, so
    /// `onFire` and the grants check may re-enter the watchdog. Returns
    /// whether the daemon was admitting work when the event arrived.
    @discardableResult
    private func send(_ event: IdleExitPolicy.Event) -> Bool {
        let (admitted, effects) = state.withLock { state -> (Bool, [IdleExitPolicy.Effect]) in
            let admitted = IdleExitPolicy.admits(state.phase)
            let (next, effects) = IdleExitPolicy.reduce(state.phase, event)
            state.phase = next
            if event == .begin, admitted { state.requestCount += 1 }
            return (admitted, effects)
        }
        for effect in effects { run(effect) }
        return admitted
    }

    private func run(_ effect: IdleExitPolicy.Effect) {
        switch effect {
        case .armIdle(let generation):
            scheduler.after(interval) { [self] in idleTimerFired(generation) }
        case .armStaleCheck:
            // A stat every few seconds; stops once the daemon is exiting or
            // the watchdog is gone. Clients verify the peer before sending a
            // frame, so a stale daemon may never be asked anything again and
            // must notice the replaced binary on its own.
            scheduler.after(staleCheckInterval) { [weak self] in self?.staleCheckFired() }
        case .checkGrants(let generation):
            scheduler.detach { [self] in
                let live = await hasLiveGrants()
                send(.grantsChecked(generation, live: live))
            }
        case .exit:
            onFire()
        }
    }

    private func idleTimerFired(_ generation: UInt64) {
        let phase = state.withLock { $0.phase }
        // Sample the binary only if the timer is still current.
        let stale = IdleExitPolicy.idleTimerReadsStale(phase, generation: generation)
            && executableChanged()
        send(.idleTimer(generation, stale: stale))
    }

    private func staleCheckFired() {
        let phase = state.withLock { $0.phase }
        let stale = IdleExitPolicy.staleTickReadsStale(phase) && executableChanged()
        send(.staleTick(stale: stale))
    }
}
