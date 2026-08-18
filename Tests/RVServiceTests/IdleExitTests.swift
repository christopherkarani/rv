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
}
