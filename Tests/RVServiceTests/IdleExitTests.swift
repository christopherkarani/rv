import Foundation
import Synchronization
import Testing
#if canImport(XPC)
@preconcurrency import XPC
#endif
@testable import RVService

@Suite(.serialized)
struct IdleExitTests {
    @Test func injectedOneSecondIdleFiresWithoutKeepAlive() async throws {
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(interval: .seconds(1), scheduler: clock.scheduler)
        watchdog.start()
        clock.advance(by: .milliseconds(999))
        await clock.runDetached()
        #expect(watchdog.hasFired == false)
        clock.advance(by: .milliseconds(1))
        await clock.runDetached()
        #expect(watchdog.hasFired)
        let configuration = try RVDLaunch.parse(arguments: ["rvd"])
        #expect(configuration.idleExitSeconds == 1800)
    }

    /// The one wall-clock test: the production scheduler really fires.
    @Test func dispatchSchedulerSmoke() async {
        let watchdog = IdleWatchdog(interval: .milliseconds(100))
        watchdog.start()
        #expect(await waitUntilIdleFired(watchdog))
    }

    @Test func defaultIdleIsThirtyMinutes() {
        #expect(IdleWatchdog.defaultSeconds == 1800)
    }

    @Test func requestResetsIdleTimer() async {
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(interval: .milliseconds(600), scheduler: clock.scheduler)
        watchdog.start()
        clock.advance(by: .milliseconds(400))
        #expect(watchdog.beginRequest())
        watchdog.endRequest()
        clock.advance(by: .milliseconds(400))
        await clock.runDetached()
        #expect(watchdog.hasFired == false)
        clock.advance(by: .milliseconds(200))
        await clock.runDetached()
        #expect(watchdog.hasFired)
    }

    @Test func neverFiresWhileARequestIsInFlight() async {
        let fired = FireCounter()
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .milliseconds(200), onFire: { fired.hit() }, scheduler: clock.scheduler)
        watchdog.start()
        #expect(watchdog.beginRequest())
        clock.advance(by: .milliseconds(700))
        await clock.runDetached()
        #expect(watchdog.hasFired == false)
        #expect(watchdog.inFlight == 1)
        watchdog.endRequest()
        clock.advance(by: .milliseconds(200))
        await clock.runDetached()
        #expect(watchdog.hasFired)
        #expect(fired.count == 1)
    }

    @Test func idleTimerDoesNotStatTheBinaryWhileARequestIsInFlight() async {
        let stats = FireCounter()
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .milliseconds(200),
            staleCheckInterval: .seconds(3600),
            executableChanged: { stats.hit(); return false },
            scheduler: clock.scheduler
        )
        watchdog.start()
        #expect(watchdog.beginRequest())
        clock.advance(by: .seconds(2))
        await clock.runDetached()
        #expect(stats.count == 0)
    }

    @Test func liveAllowOnceGrantsRearmInsteadOfExiting() async {
        let live = Mutex(true)
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .milliseconds(200),
            hasLiveGrants: { live.withLock { $0 } },
            scheduler: clock.scheduler
        )
        watchdog.start()
        for _ in 0..<4 {
            clock.advance(by: .milliseconds(200))
            await clock.runDetached()
        }
        #expect(watchdog.hasFired == false)
        live.withLock { $0 = false }
        clock.advance(by: .milliseconds(200))
        await clock.runDetached()
        #expect(watchdog.hasFired)
    }

    /// `hasLiveGrants` calls back into the watchdog (`beginRequest`) while the
    /// exit check is pending: the decision must see the request and stand down.
    @Test func requestArrivingDuringTheExitCheckCancelsTheExit() async {
        let slot = WatchdogSlot()
        let admitted = Mutex<Bool?>(nil)
        let checks = FireCounter()
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .milliseconds(150),
            hasLiveGrants: {
                checks.hit()
                // A request lands between the timer firing and the exit
                // decision: the decision must see it and stand down.
                if admitted.withLock({ $0 }) == nil {
                    let ok = slot.watchdog?.beginRequest() ?? false
                    admitted.withLock { $0 = ok }
                }
                return false
            },
            scheduler: clock.scheduler
        )
        slot.watchdog = watchdog
        watchdog.start()
        clock.advance(by: .milliseconds(150))
        await clock.runDetached()
        #expect(checks.count == 1)
        #expect(admitted.withLock { $0 } == true)
        #expect(watchdog.hasFired == false)
        #expect(watchdog.inFlight == 1)
        watchdog.endRequest()
        clock.advance(by: .milliseconds(150))
        await clock.runDetached()
        #expect(watchdog.hasFired)
    }

    /// CON-001: effects run after the lock is released, so `onFire` may call
    /// back into the watchdog. The callback probes from another thread with a
    /// deadline: a regression that fires under the lock fails here instead of
    /// hanging the suite.
    @Test func onFireRunsOutsideTheLock() async {
        let slot = WatchdogSlot()
        let probed = Mutex<Bool?>(nil)
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .milliseconds(100),
            onFire: {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = slot.watchdog?.hasFired
                    done.signal()
                }
                probed.withLock { $0 = done.wait(timeout: .now() + .seconds(5)) == .success }
            },
            scheduler: clock.scheduler
        )
        slot.watchdog = watchdog
        watchdog.start()
        clock.advance(by: .milliseconds(100))
        await clock.runDetached()
        #expect(watchdog.hasFired)
        #expect(probed.withLock { $0 } == true)
    }

    @Test func onceExitIsDecidedNewRequestsAreRefused() async {
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(interval: .milliseconds(100), scheduler: clock.scheduler)
        watchdog.start()
        clock.advance(by: .milliseconds(100))
        await clock.runDetached()
        #expect(watchdog.hasFired)
        #expect(watchdog.beginRequest() == false)
        #expect(watchdog.inFlight == 0)
    }

    @Test func replacedExecutableExitsAfterTheRequestCompletes() {
        let changed = Mutex(false)
        let fired = FireCounter()
        let watchdog = IdleWatchdog(
            seconds: 300,
            executableChanged: { changed.withLock { $0 } },
            onFire: { fired.hit() }
        )
        watchdog.start()
        #expect(watchdog.beginRequest())
        watchdog.endRequest()
        #expect(fired.count == 0)

        #expect(watchdog.beginRequest())
        changed.withLock { $0 = true }
        watchdog.endRequest()
        #expect(fired.count == 1)
        #expect(watchdog.hasFired)
        #expect(watchdog.beginRequest() == false)
    }

    @Test func replacedExecutableDrainsInFlightRequestsBeforeExit() {
        let changed = Mutex(false)
        let fired = FireCounter()
        let watchdog = IdleWatchdog(
            seconds: 300,
            executableChanged: { changed.withLock { $0 } },
            onFire: { fired.hit() }
        )
        #expect(watchdog.beginRequest())
        #expect(watchdog.beginRequest())
        changed.withLock { $0 = true }
        watchdog.endRequest()
        #expect(fired.count == 0)
        // Draining: the stale daemon takes no new work.
        #expect(watchdog.beginRequest() == false)
        watchdog.endRequest()
        #expect(fired.count == 1)
    }

    @Test func replacedExecutableExitsOnIdleCheck() async {
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .milliseconds(100),
            hasLiveGrants: { true },
            executableChanged: { true },
            scheduler: clock.scheduler
        )
        watchdog.start()
        clock.advance(by: .milliseconds(100))
        await clock.runDetached()
        // Live grants would re-arm, but a replaced binary cannot serve
        // anyone (clients pin the on-disk cdhash): exit anyway.
        #expect(watchdog.hasFired)
    }

    @Test func replacedExecutableExitsWithinTheStaleCheckWhileIdle() async {
        // Clients verify the peer before sending a frame, so a stale daemon
        // may never see another request; only a periodic check finds it.
        let changed = Mutex(false)
        let fired = FireCounter()
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .seconds(3600),
            staleCheckInterval: .milliseconds(50),
            executableChanged: { changed.withLock { $0 } },
            onFire: { fired.hit() },
            scheduler: clock.scheduler
        )
        watchdog.start()
        clock.advance(by: .milliseconds(200))
        #expect(watchdog.hasFired == false)
        changed.withLock { $0 = true }
        clock.advance(by: .milliseconds(50))
        #expect(watchdog.hasFired)
        #expect(fired.count == 1)
        // The check stops rearming once the daemon is exiting.
        clock.advance(by: .seconds(1))
        #expect(fired.count == 1)
        #expect(clock.pendingTimers == 1)  // only the idle timer
    }

    @Test func staleCheckDrainsAnInFlightRequestBeforeExit() async {
        let fired = FireCounter()
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(
            interval: .seconds(3600),
            staleCheckInterval: .milliseconds(50),
            executableChanged: { true },
            onFire: { fired.hit() },
            scheduler: clock.scheduler
        )
        #expect(watchdog.beginRequest())
        watchdog.start()
        clock.advance(by: .milliseconds(300))
        #expect(fired.count == 0)
        // Draining: no new work, and the in-flight request ends the process.
        #expect(watchdog.beginRequest() == false)
        watchdog.endRequest()
        #expect(fired.count == 1)
    }

    @Test func staleCheckStopsWhenTheWatchdogIsGone() {
        let clock = ManualIdleScheduler()
        var watchdog: IdleWatchdog? = IdleWatchdog(
            interval: .seconds(3600),
            staleCheckInterval: .milliseconds(50),
            scheduler: clock.scheduler
        )
        // In flight, so `start` arms only the stale check: no idle timer
        // (which owns its watchdog) keeps it alive.
        #expect(watchdog?.beginRequest() == true)
        watchdog?.start()
        weak let probe = watchdog
        watchdog = nil
        #expect(probe == nil)
        // An unchanged binary would rearm forever if the check held the watchdog.
        clock.advance(by: .seconds(1))
        #expect(clock.pendingTimers == 0)
    }

    @Test func defaultStaleCheckIsShort() {
        #expect(IdleWatchdog.defaultStaleCheckInterval <= .seconds(5))
    }

    @Test func executableProbeSeesReplacementAndRewrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-exe-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("rvd")
        try Data("old".utf8).write(to: binary)

        let probe = try #require(ExecutableChangeProbe(path: binary.path))
        #expect(probe.hasChanged() == false)

        // Atomic replace (rename over): new inode.
        let staged = dir.appendingPathComponent("rvd.new")
        try Data("new".utf8).write(to: staged)
        _ = try FileManager.default.replaceItemAt(binary, withItemAt: staged)
        #expect(probe.hasChanged())

        let rewritten = try #require(ExecutableChangeProbe(path: binary.path))
        #expect(rewritten.hasChanged() == false)
        try Data("longer contents".utf8).write(to: binary, options: [])
        #expect(rewritten.hasChanged())

        let removed = try #require(ExecutableChangeProbe(path: binary.path))
        try FileManager.default.removeItem(at: binary)
        #expect(removed.hasChanged())
    }

    @Test func runningExecutableProbeResolvesAndIsStable() throws {
        let probe = try #require(ExecutableChangeProbe.running())
        #expect(probe.path.hasPrefix("/"))
        #expect(probe.hasChanged() == false)
    }

    #if canImport(XPC)
    @Test func bootArmAndHandleResetIdleTimer() async throws {
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(interval: .seconds(1), scheduler: clock.scheduler)
        watchdog.start()
        clock.advance(by: .milliseconds(400))

        let session = XPCPeerSession(runtime: try isolatedRuntime(), watchdog: watchdog)
        let task = try #require(session.handle(xpc_dictionary_create_empty()))
        await task.value

        clock.advance(by: .milliseconds(800))
        await clock.runDetached()
        #expect(watchdog.hasFired == false)
        #expect(watchdog.requestCount == 1)
        #expect(watchdog.inFlight == 0)
        clock.advance(by: .milliseconds(200))
        await clock.runDetached()
        #expect(watchdog.hasFired)
    }

    @Test func handleAfterExitDecisionIsDropped() async throws {
        let clock = ManualIdleScheduler()
        let watchdog = IdleWatchdog(interval: .milliseconds(100), scheduler: clock.scheduler)
        watchdog.start()
        clock.advance(by: .milliseconds(100))
        await clock.runDetached()
        #expect(watchdog.hasFired)
        let session = XPCPeerSession(runtime: try isolatedRuntime(), watchdog: watchdog)
        #expect(session.handle(xpc_dictionary_create_empty()) == nil)
        #expect(watchdog.requestCount == 0)
    }
    #endif
}

private final class FireCounter: Sendable {
    private let box = Mutex(0)
    var count: Int { box.withLock { $0 } }
    func hit() { box.withLock { $0 += 1 } }
}

private final class WatchdogSlot: Sendable {
    private let box = Mutex<IdleWatchdog?>(nil)
    var watchdog: IdleWatchdog? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}

/// A short watchdog is too tight under a parallel suite for a fixed sleep:
/// the fire can miss the window. Poll with a 15s deadline.
private func waitUntilIdleFired(
    _ watchdog: IdleWatchdog,
    timeout: Duration = .seconds(15)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if watchdog.hasFired { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return watchdog.hasFired
}

/// Hand-driven clock and executor for `IdleWatchdog`.
final class ManualIdleScheduler: Sendable {
    private struct Timer { let due: Duration; let seq: Int; let work: @Sendable () -> Void }
    private struct State {
        var now: Duration = .zero
        var seq = 0
        var timers: [Timer] = []
        var detached: [@Sendable () async -> Void] = []
    }
    private let state = Mutex(State())

    var scheduler: IdleExitScheduler {
        IdleExitScheduler(
            after: { [self] delay, work in
                state.withLock { s in
                    s.seq += 1
                    s.timers.append(Timer(due: s.now + delay, seq: s.seq, work: work))
                }
            },
            detach: { [self] work in state.withLock { $0.detached.append(work) } }
        )
    }

    var pendingTimers: Int { state.withLock { $0.timers.count } }

    /// Runs every timer due within `duration`, in due order, including ones
    /// armed by the timers themselves.
    func advance(by duration: Duration) {
        let target = state.withLock { $0.now + duration }
        while true {
            let next = state.withLock { s -> Timer? in
                guard let i = s.timers.indices
                    .filter({ s.timers[$0].due <= target })
                    .min(by: { (s.timers[$0].due, s.timers[$0].seq) < (s.timers[$1].due, s.timers[$1].seq) })
                else { return nil }
                let timer = s.timers.remove(at: i)
                s.now = timer.due
                return timer
            }
            guard let next else { break }
            next.work()
        }
        state.withLock { $0.now = target }
    }

    /// Runs queued detached work to completion, including work it queues.
    func runDetached() async {
        while let work = state.withLock({ $0.detached.isEmpty ? nil : $0.detached.removeFirst() }) {
            await work()
        }
    }
}

