import Testing
@testable import RVService

struct IdleExitPolicyTests {
    typealias P = IdleExitPolicy
    private func serving(_ n: Int, _ g: UInt64) -> P.Phase { .serving(inFlight: n, generation: g) }

    // MARK: start

    @Test func startArmsIdleAndStaleCheckWhenIdle() {
        let (phase, effects) = P.reduce(serving(0, 0), .start)
        #expect(phase == serving(0, 1))
        #expect(effects == [.armIdle(1), .armStaleCheck])
    }

    @Test func startWithWorkInFlightOnlyArmsStaleCheck() {
        let (phase, effects) = P.reduce(serving(1, 4), .start)
        #expect(phase == serving(1, 4))
        #expect(effects == [.armStaleCheck])
    }

    @Test func startAfterExitStillArmsStaleCheckOnly() {
        #expect(P.reduce(.exited, .start) == (.exited, [.armStaleCheck]))
    }

    // MARK: begin

    @Test func beginAdmitsAndBumpsGeneration() {
        #expect(P.reduce(serving(0, 3), .begin) == (serving(1, 4), []))
        #expect(P.admits(serving(0, 3)))
    }

    @Test func beginIsRefusedWhileDrainingOrExited() {
        #expect(P.reduce(.draining(inFlight: 1), .begin) == (.draining(inFlight: 1), []))
        #expect(P.reduce(.exited, .begin) == (.exited, []))
        #expect(P.admits(.draining(inFlight: 1)) == false)
        #expect(P.admits(.exited) == false)
    }

    // MARK: end

    @Test func lastEndRearmsIdleWithFreshGeneration() {
        #expect(P.reduce(serving(1, 5), .end(stale: false)) == (serving(0, 6), [.armIdle(6)]))
    }

    @Test func endWithWorkInFlightKeepsGenerationAndArmsNothing() {
        #expect(P.reduce(serving(2, 5), .end(stale: false)) == (serving(1, 5), []))
    }

    @Test func endClampsInFlightAtZero() {
        #expect(P.reduce(serving(0, 5), .end(stale: false)) == (serving(0, 6), [.armIdle(6)]))
    }

    @Test func staleEndAtZeroExits() {
        #expect(P.reduce(serving(1, 5), .end(stale: true)) == (.exited, [.exit]))
    }

    @Test func staleEndWithWorkInFlightDrains() {
        #expect(P.reduce(serving(2, 5), .end(stale: true)) == (.draining(inFlight: 1), []))
    }

    @Test func drainingExitsOnLastEnd() {
        #expect(P.reduce(.draining(inFlight: 2), .end(stale: false)) == (.draining(inFlight: 1), []))
        #expect(P.reduce(.draining(inFlight: 1), .end(stale: false)) == (.exited, [.exit]))
    }

    @Test func endAfterExitIsInert() {
        #expect(P.reduce(.exited, .end(stale: true)) == (.exited, []))
    }

    // MARK: idle timer

    @Test func currentIdleTimerChecksGrants() {
        #expect(P.reduce(serving(0, 7), .idleTimer(7, stale: false)) == (serving(0, 7), [.checkGrants(7)]))
    }

    @Test func staleIdleTimerExitsRegardlessOfGrants() {
        #expect(P.reduce(serving(0, 7), .idleTimer(7, stale: true)) == (.exited, [.exit]))
    }

    @Test func idleTimerIsNoOpOnGenerationMismatchInFlightOrExit() {
        for phase in [serving(0, 8), serving(1, 7), .draining(inFlight: 1), .exited] {
            #expect(P.reduce(phase, .idleTimer(7, stale: true)) == (phase, []))
        }
    }

    @Test func idleTimerSamplesTheBinaryOnlyWhenCurrent() {
        #expect(P.idleTimerReadsStale(serving(0, 7), generation: 7))
        #expect(P.idleTimerReadsStale(serving(0, 8), generation: 7) == false)
        #expect(P.idleTimerReadsStale(serving(1, 7), generation: 7) == false)
        #expect(P.idleTimerReadsStale(.exited, generation: 7) == false)
    }

    // MARK: grants

    @Test func liveGrantsRearmWithFreshGeneration() {
        #expect(P.reduce(serving(0, 7), .grantsChecked(7, live: true)) == (serving(0, 8), [.armIdle(8)]))
    }

    @Test func noLiveGrantsExit() {
        #expect(P.reduce(serving(0, 7), .grantsChecked(7, live: false)) == (.exited, [.exit]))
    }

    @Test func requestDuringGrantsCheckCancelsTheExit() {
        let (admitted, _) = P.reduce(serving(0, 7), .begin)
        #expect(P.reduce(admitted, .grantsChecked(7, live: false)) == (admitted, []))
        let (done, _) = P.reduce(admitted, .end(stale: false))
        #expect(P.reduce(done, .grantsChecked(7, live: true)) == (done, []))
    }

    // MARK: stale tick

    @Test func unchangedTickRearms() {
        #expect(P.reduce(serving(2, 1), .staleTick(stale: false)) == (serving(2, 1), [.armStaleCheck]))
        #expect(P.reduce(.draining(inFlight: 1), .staleTick(stale: false)) == (.draining(inFlight: 1), [.armStaleCheck]))
    }

    @Test func changedTickWhenIdleExits() {
        #expect(P.reduce(serving(0, 1), .staleTick(stale: true)) == (.exited, [.exit]))
    }

    @Test func changedTickWithWorkInFlightDrainsAndStopsRearming() {
        #expect(P.reduce(serving(2, 1), .staleTick(stale: true)) == (.draining(inFlight: 2), []))
        #expect(P.reduce(.draining(inFlight: 2), .staleTick(stale: true)) == (.draining(inFlight: 2), []))
    }

    @Test func tickStopsOnceExited() {
        #expect(P.reduce(.exited, .staleTick(stale: false)) == (.exited, []))
        #expect(P.reduce(.exited, .staleTick(stale: true)) == (.exited, []))
        #expect(P.staleTickReadsStale(.exited) == false)
        #expect(P.staleTickReadsStale(serving(0, 0)))
    }

    // MARK: exhaustive sequences

    @Test func exitIsEmittedAtMostOnceAndOnlyFromIdle() {
        let events: [P.Event] = [
            .start, .begin, .end(stale: false), .end(stale: true),
            .idleTimer(1, stale: false), .idleTimer(1, stale: true),
            .idleTimer(2, stale: false), .grantsChecked(1, live: true),
            .grantsChecked(1, live: false), .grantsChecked(2, live: false),
            .staleTick(stale: false), .staleTick(stale: true),
        ]
        // Sequences of length <= 6, memoized on (phase, exits so far, depth):
        // the reducer is a function of phase and event only.
        struct Node: Hashable { let phase: String; let exits: Int; let depth: Int }
        var seen = Set<Node>()
        var checked = 0
        func walk(_ phase: P.Phase, _ depth: Int, _ exits: Int) {
            guard depth < 6, seen.insert(Node(phase: "\(phase)", exits: exits, depth: depth)).inserted else { return }
            checked += 1
            for event in events {
                let (next, effects) = P.reduce(phase, event)
                let emitted = effects.filter { $0 == .exit }.count
                if emitted > 0 {
                    #expect(phase != .exited, "exit after exited on \(event)")
                    #expect(emitted == 1 && exits == 0, "second exit on \(event)")
                    switch phase {
                    case .serving(let n, _): #expect(n <= 1, "exit with \(n) in flight on \(event)")
                    case .draining(let n): #expect(n == 1, "exit while draining with \(n) in flight")
                    case .exited: break
                    }
                    #expect(next == .exited)
                }
                if case .draining(let n) = next { #expect(n > 0) }
                if phase == .exited { #expect(next == .exited) }
                walk(next, depth + 1, exits + emitted)
            }
        }
        walk(P.initial, 0, 0)
        #expect(checked > 20)
    }
}
