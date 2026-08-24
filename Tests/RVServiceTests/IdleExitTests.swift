import Foundation
import Testing
@testable import RVService

struct IdleExitTests {
    @Test func injectedOneSecondIdleFiresWithoutKeepAlive() async throws {
        let watchdog = IdleWatchdog(seconds: 1)
        await watchdog.ping()
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(await watchdog.fired)
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
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(await watchdog.fired)
    }

    @Test func handleIncoming_recordsActivity() async throws {
        let hits = ActivityHits()
        let runtime = try isolatedRuntime(onActivity: { await hits.increment() })
        #expect(await hits.count == 0)
        _ = await runtime.handleIncoming(Data(), handshakeOK: false)
        #expect(await hits.count == 1)
    }
}

private actor ActivityHits {
    private(set) var count = 0
    func increment() { count += 1 }
}
