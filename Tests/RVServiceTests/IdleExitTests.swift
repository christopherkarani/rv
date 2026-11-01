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
        let watchdog = IdleWatchdog(seconds: 1)
        watchdog.start()
        #expect(await waitUntilIdleFired(watchdog))
        let configuration = try RVDLaunch.parse(arguments: ["rvd"])
        #expect(configuration.idleExitSeconds == 1800)
    }

    @Test func defaultIdleIsThirtyMinutes() {
        #expect(IdleWatchdog.defaultSeconds == 1800)
    }

    @Test func requestResetsIdleTimer() async {
        let watchdog = IdleWatchdog(interval: .milliseconds(600))
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(watchdog.beginRequest())
        watchdog.endRequest()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(watchdog.hasFired == false)
        #expect(await waitUntilIdleFired(watchdog))
    }

    @Test func neverFiresWhileARequestIsInFlight() async {
        let fired = FireCounter()
        let watchdog = IdleWatchdog(interval: .milliseconds(200), onFire: { fired.hit() })
        watchdog.start()
        #expect(watchdog.beginRequest())
        try? await Task.sleep(for: .milliseconds(700))
        #expect(watchdog.hasFired == false)
        #expect(watchdog.inFlight == 1)
        watchdog.endRequest()
        #expect(await waitUntilIdleFired(watchdog))
        #expect(fired.count == 1)
    }

    @Test func liveAllowOnceGrantsRearmInsteadOfExiting() async {
        let live = Mutex(true)
        let watchdog = IdleWatchdog(
            interval: .milliseconds(200),
            hasLiveGrants: { live.withLock { $0 } }
        )
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(800))
        #expect(watchdog.hasFired == false)
        live.withLock { $0 = false }
        #expect(await waitUntilIdleFired(watchdog))
    }

    @Test func requestArrivingDuringTheExitCheckCancelsTheExit() async {
        let slot = WatchdogSlot()
        let admitted = Mutex<Bool?>(nil)
        let checks = FireCounter()
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
            }
        )
        slot.watchdog = watchdog
        watchdog.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while checks.count == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(admitted.withLock { $0 } == true)
        #expect(watchdog.hasFired == false)
        #expect(watchdog.inFlight == 1)
        watchdog.endRequest()
        #expect(await waitUntilIdleFired(watchdog))
    }

    @Test func onceExitIsDecidedNewRequestsAreRefused() async {
        let watchdog = IdleWatchdog(interval: .milliseconds(100))
        watchdog.start()
        #expect(await waitUntilIdleFired(watchdog))
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
        let watchdog = IdleWatchdog(
            interval: .milliseconds(100),
            hasLiveGrants: { true },
            executableChanged: { true }
        )
        watchdog.start()
        // Live grants would re-arm, but a replaced binary cannot serve
        // anyone (clients pin the on-disk cdhash): exit anyway.
        #expect(await waitUntilIdleFired(watchdog))
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
        let watchdog = IdleWatchdog(interval: .seconds(1))
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(400))

        let session = XPCPeerSession(runtime: try isolatedRuntime(), watchdog: watchdog)
        let task = try #require(session.handle(xpc_dictionary_create_empty()))
        await task.value

        try? await Task.sleep(for: .milliseconds(400))
        #expect(watchdog.hasFired == false)
        #expect(watchdog.requestCount == 1)
        #expect(watchdog.inFlight == 0)
        #expect(await waitUntilIdleFired(watchdog))
    }

    @Test func handleAfterExitDecisionIsDropped() async throws {
        let watchdog = IdleWatchdog(interval: .milliseconds(100))
        watchdog.start()
        #expect(await waitUntilIdleFired(watchdog))
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
