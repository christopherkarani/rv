import Foundation
import Testing
#if canImport(XPC)
@preconcurrency import XPC
#endif
@testable import RVService

@Suite(.serialized)
struct IdleExitTests {
    @Test func injectedOneSecondIdleFiresWithoutKeepAlive() async throws {
        let watchdog = IdleWatchdog(seconds: 1)
        await watchdog.ping()
        #expect(await waitUntilIdleFired(watchdog))
        let configuration = try RVDLaunch.parse(arguments: ["rvd"])
        #expect(configuration.idleExitSeconds == 300)
    }

    @Test func pingResetsIdleTimer() async {
        let watchdog = IdleWatchdog(seconds: 1)
        await watchdog.ping()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await watchdog.ping()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(await watchdog.fired == false)
        #expect(await waitUntilIdleFired(watchdog))
    }

    #if canImport(XPC)
    @Test func bootPingAndHandlePingResetIdleTimer() async throws {
        let watchdog = IdleWatchdog(seconds: 1)
        await watchdog.ping()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let session = XPCPeerSession(runtime: try isolatedRuntime(), watchdog: watchdog)
        let task = try #require(session.handle(xpc_dictionary_create_empty()))
        await task.value

        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(await watchdog.fired == false)
        #expect(await watchdog.pingCount == 2)
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(await watchdog.fired)
    }
    #endif
}

/// `Task.sleep` after a 1s watchdog is too tight under a parallel Linux
/// suite: the fire task can miss the window. Poll with a 15s deadline.
private func waitUntilIdleFired(
    _ watchdog: IdleWatchdog,
    timeoutNanoseconds: UInt64 = 15_000_000_000
) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if await watchdog.fired { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await watchdog.fired
}
