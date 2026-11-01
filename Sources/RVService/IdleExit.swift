import Dispatch
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
        var inFlight = 0
        /// Bumped on every admitted request and every (re)arm; a timer only
        /// acts if the generation it was armed with is still current.
        var generation: UInt64 = 0
        var draining = false
        var exiting = false
        var requestCount = 0
    }

    private let state = Mutex(State())
    private let interval: Duration
    private let staleCheckInterval: Duration
    private let hasLiveGrants: @Sendable () async -> Bool
    private let executableChanged: @Sendable () -> Bool
    private let onFire: @Sendable () -> Void
    private let queue = DispatchQueue(label: "rv.idle-watchdog", qos: .utility)

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
        onFire: @escaping @Sendable () -> Void = {}
    ) {
        self.interval = interval
        self.staleCheckInterval = staleCheckInterval
        self.hasLiveGrants = hasLiveGrants
        self.executableChanged = executableChanged
        self.onFire = onFire
    }

    /// True once the exit decision was taken.
    public var hasFired: Bool { state.withLock { $0.exiting } }
    var inFlight: Int { state.withLock { $0.inFlight } }
    var requestCount: Int { state.withLock { $0.requestCount } }

    /// Boot: arm the idle timer before the first request arrives.
    public func start() {
        let generation = state.withLock { state -> UInt64? in
            guard state.exiting == false, state.inFlight == 0 else { return nil }
            state.generation &+= 1
            return state.generation
        }
        if let generation { schedule(generation) }
        scheduleStaleCheck()
    }

    /// Admits one request. Call synchronously on receipt, before any work.
    /// False once the daemon is exiting or draining: drop the request (the
    /// client reconnects to the relaunched daemon).
    public func beginRequest() -> Bool {
        state.withLock { state in
            guard state.exiting == false, state.draining == false else { return false }
            state.inFlight += 1
            state.requestCount += 1
            state.generation &+= 1
            return true
        }
    }

    /// Ends one admitted request, after its reply was handed to the transport.
    public func endRequest() {
        let stale = executableChanged()
        enum Next { case none, arm(UInt64), exit }
        let next = state.withLock { state -> Next in
            state.inFlight = max(0, state.inFlight - 1)
            if stale { state.draining = true }
            guard state.inFlight == 0, state.exiting == false else { return .none }
            if state.draining {
                state.exiting = true
                return .exit
            }
            state.generation &+= 1
            return .arm(state.generation)
        }
        switch next {
        case .none: break
        case .arm(let generation): schedule(generation)
        case .exit: onFire()
        }
    }

    private func schedule(_ generation: UInt64) {
        queue.asyncAfter(deadline: .now() + dispatchInterval(interval)) { [self] in
            timerFired(generation)
        }
    }

    /// Clients verify the peer before sending a frame, so a stale daemon may
    /// never be asked anything again; it must notice the replaced binary on
    /// its own. A stat every few seconds; stops once the daemon is exiting
    /// or the watchdog is gone.
    private func scheduleStaleCheck() {
        queue.asyncAfter(deadline: .now() + dispatchInterval(staleCheckInterval)) { [weak self] in
            self?.staleCheckFired()
        }
    }

    private func staleCheckFired() {
        guard state.withLock({ $0.exiting }) == false else { return }
        guard executableChanged() else {
            scheduleStaleCheck()
            return
        }
        let exit = state.withLock { state -> Bool in
            state.draining = true
            guard state.inFlight == 0, state.exiting == false else { return false }
            state.exiting = true
            return true
        }
        // With work in flight, the last `endRequest` exits (draining).
        if exit { onFire() }
    }

    private func timerFired(_ generation: UInt64) {
        guard isIdle(at: generation) else { return }
        if executableChanged() {
            exitIfStillIdle(at: generation)
            return
        }
        Task.detached(priority: .utility) { [self] in
            if await hasLiveGrants() {
                rearmIfStillIdle(at: generation)
            } else {
                exitIfStillIdle(at: generation)
            }
        }
    }

    private func isIdle(at generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation && $0.inFlight == 0 && $0.exiting == false }
    }

    /// The decision is atomic with `beginRequest`: a request admitted after
    /// the timer was armed bumped the generation, so this stands down.
    private func exitIfStillIdle(at generation: UInt64) {
        let decided = state.withLock { state -> Bool in
            guard state.generation == generation, state.inFlight == 0, state.exiting == false else {
                return false
            }
            state.exiting = true
            return true
        }
        if decided { onFire() }
    }

    private func rearmIfStillIdle(at generation: UInt64) {
        let next = state.withLock { state -> UInt64? in
            guard state.generation == generation, state.inFlight == 0, state.exiting == false else {
                return nil
            }
            state.generation &+= 1
            return state.generation
        }
        if let next { schedule(next) }
    }
}
