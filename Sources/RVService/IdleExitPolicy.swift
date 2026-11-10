import Dispatch

/// Pure decision core of `IdleWatchdog`: what the daemon does on each event.
/// No clocks, locks or I/O; the watchdog interprets the returned effects
/// after releasing its lock.
enum IdleExitPolicy {
    enum Phase: Equatable {
        /// Admitting work. `generation` is bumped on every admitted request
        /// and every (re)arm; a timer only acts if its generation is current.
        case serving(inFlight: Int, generation: UInt64)
        /// Executable replaced: admits nothing, exits when `inFlight` hits 0.
        /// `inFlight` is always > 0 (both setters go straight to `.exited`).
        case draining(inFlight: Int)
        /// Exit decided; admits nothing.
        case exited
    }

    enum Event: Equatable {
        case start
        case begin
        case end(stale: Bool)
        case idleTimer(UInt64, stale: Bool)
        case grantsChecked(UInt64, live: Bool)
        case staleTick(stale: Bool)
    }

    enum Effect: Equatable {
        case armIdle(UInt64)
        case armStaleCheck
        case checkGrants(UInt64)
        case exit
    }

    static let initial = Phase.serving(inFlight: 0, generation: 0)

    static func admits(_ phase: Phase) -> Bool {
        if case .serving = phase { return true }
        return false
    }

    /// Whether `reduce` reads `stale` for an `.idleTimer(generation, …)`
    /// in `phase`: only a timer that is still current samples the binary.
    static func idleTimerReadsStale(_ phase: Phase, generation: UInt64) -> Bool {
        if case .serving(0, generation) = phase { return true }
        return false
    }

    /// Whether `reduce` reads `stale` for a `.staleTick` in `phase`.
    static func staleTickReadsStale(_ phase: Phase) -> Bool { phase != .exited }

    static func reduce(_ phase: Phase, _ event: Event) -> (Phase, [Effect]) {
        switch (phase, event) {
        case (.serving(let inFlight, let generation), .start):
            guard inFlight == 0 else { return (phase, [.armStaleCheck]) }
            return (.serving(inFlight: 0, generation: generation &+ 1),
                    [.armIdle(generation &+ 1), .armStaleCheck])
        case (_, .start):
            return (phase, [.armStaleCheck])

        case (.serving(let inFlight, let generation), .begin):
            return (.serving(inFlight: inFlight + 1, generation: generation &+ 1), [])
        case (_, .begin):
            return (phase, [])

        case (.serving(let inFlight, let generation), .end(let stale)):
            let remaining = max(0, inFlight - 1)
            if remaining > 0 {
                return (stale ? .draining(inFlight: remaining)
                              : .serving(inFlight: remaining, generation: generation), [])
            }
            if stale { return (.exited, [.exit]) }
            return (.serving(inFlight: 0, generation: generation &+ 1), [.armIdle(generation &+ 1)])
        case (.draining(let inFlight), .end):
            let remaining = max(0, inFlight - 1)
            return remaining == 0 ? (.exited, [.exit]) : (.draining(inFlight: remaining), [])
        case (.exited, .end):
            return (phase, [])

        case (.serving(0, let current), .idleTimer(let generation, let stale)) where current == generation:
            return stale ? (.exited, [.exit]) : (phase, [.checkGrants(generation)])
        case (_, .idleTimer):
            return (phase, [])

        case (.serving(0, let current), .grantsChecked(let generation, let live)) where current == generation:
            return live
                ? (.serving(inFlight: 0, generation: current &+ 1), [.armIdle(current &+ 1)])
                : (.exited, [.exit])
        case (_, .grantsChecked):
            return (phase, [])

        case (.exited, .staleTick):
            return (phase, [])
        case (_, .staleTick(false)):
            return (phase, [.armStaleCheck])
        case (.serving(0, _), .staleTick(true)):
            return (.exited, [.exit])
        case (.serving(let inFlight, _), .staleTick(true)):
            return (.draining(inFlight: inFlight), [])
        case (.draining, .staleTick(true)):
            return (phase, [])
        }
    }
}

/// Clock and executor seam for `IdleWatchdog`; tests drive it by hand.
struct IdleExitScheduler: Sendable {
    var after: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
    var detach: @Sendable (@escaping @Sendable () async -> Void) -> Void

    static func dispatch(label: String) -> IdleExitScheduler {
        let queue = DispatchQueue(label: label, qos: .utility)
        return IdleExitScheduler(
            after: { delay, work in
                queue.asyncAfter(deadline: .now() + dispatchInterval(delay), execute: work)
            },
            detach: { work in
                Task.detached(priority: .utility) { await work() }
            }
        )
    }
}
