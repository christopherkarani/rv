import Foundation
import Testing
@testable import RVAnalytics

/// rvd records analytics for every decision. Each decision used to rewrite
/// `analytics-counters.json` twice (an atomic replace with fsync, ~2 ms on
/// Linux): once for the count and once for an unchanged pack list. Counts
/// now reach the file at most once per `persistDelay`, an unchanged pack
/// list writes nothing, and everything else still writes at once.
struct AnalyticsCounterPersistenceTests {
    private static func coordinator(
        _ root: URL,
        sink: any AnalyticsSink = RecordingAnalyticsSink(),
        persistDelay: Duration
    ) -> AnalyticsCoordinator {
        AnalyticsCoordinator(
            paths: AnalyticsPaths(configDirectory: root),
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354"),
            persistDelay: persistDelay
        )
    }

    private static func saved(_ root: URL) throws -> AnalyticsCounterState {
        let data = try Data(contentsOf: AnalyticsPaths(configDirectory: root).countersFile)
        return try JSONDecoder().decode(AnalyticsCounterState.self, from: data)
    }

    private static func savedBytes(_ root: URL) -> Data? {
        try? Data(contentsOf: AnalyticsPaths(configDirectory: root).countersFile)
    }

    @Test func decisionsDoNotRewriteTheCountersFileEachTime() async throws {
        let root = try temporaryConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = Self.coordinator(root, persistDelay: .seconds(600))
        await analytics.noteEnabledPacks(["core.git", "core.fs"])
        let before = try #require(Self.savedBytes(root))
        for _ in 0..<50 {
            // What rvd sends per decision.
            await analytics.recordDecision(.deny)
            await analytics.noteEnabledPacks(["core.fs", "core.git"])
        }
        // The old coordinator rewrote the file 100 times here.
        #expect(Self.savedBytes(root) == before)
    }

    @Test func countsReachTheFileAfterTheDelay() async throws {
        let root = try temporaryConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = Self.coordinator(root, persistDelay: .milliseconds(50))
        for index in 0..<30 {
            await analytics.recordDecision(index % 3 == 0 ? .deny : .allow)
        }
        await analytics.recordDecision(.indeterminate)
        // Generous: only checks the deferred write happens, not how soon.
        let deadline = ContinuousClock.now + .seconds(30)
        var state = try? Self.saved(root)
        while state?.indeterminateCount != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            state = try? Self.saved(root)
        }
        #expect(state?.allowCount == 20)
        #expect(state?.denyCount == 10)
        #expect(state?.indeterminateCount == 1)
    }

    /// rvd's idle and replaced-binary exits write pending counts first.
    @Test func pendingCountsAreWrittenOnRequestAndSurviveARestart() async throws {
        let root = try temporaryConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = Self.coordinator(root, persistDelay: .seconds(600))
        for index in 0..<30 {
            await analytics.recordDecision(index % 3 == 0 ? .deny : .allow)
        }
        await analytics.recordDecision(.indeterminate)
        #expect(Self.savedBytes(root) == nil)
        await analytics.persistPendingNow()
        let state = try Self.saved(root)
        #expect(state.allowCount == 20)
        #expect(state.denyCount == 10)
        #expect(state.indeterminateCount == 1)

        // A restarted rvd reports the saved counts on its next daily flush.
        let sink = RecordingAnalyticsSink()
        let restarted = Self.coordinator(root, sink: sink, persistDelay: .seconds(600))
        await restarted.flushDailyIfNeeded(now: day(2099, 1, 2))
        let daily = try #require(await sink.events.last)
        #expect(daily.properties["allow_count"] == .int(20))
        #expect(daily.properties["deny_count"] == .int(10))
        #expect(daily.properties["indeterminate_count"] == .int(1))
    }

    @Test func aPackChangeAndTheDailyFlushWriteAtOnce() async throws {
        let root = try temporaryConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = Self.coordinator(root, persistDelay: .seconds(600))
        await analytics.noteEnabledPacks(["core.git"])
        #expect(try Self.saved(root).enabledPackIDs == ["core.git"])
        await analytics.noteEnabledPacks(["core.git", "core.fs"])
        #expect(try Self.saved(root).enabledPackIDs == ["core.fs", "core.git"])

        await analytics.recordDecision(.allow)
        await analytics.flushDailyIfNeeded(now: day(2099, 1, 3))
        let flushed = try Self.saved(root)
        #expect(flushed.lastFlushDay == "2099-01-03")
        #expect(flushed.allowCount == 0, "the accepted flush reset the counts on disk")
    }

    @Test func nothingPendingWritesNothing() async throws {
        let root = try temporaryConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = Self.coordinator(root, persistDelay: .seconds(600))
        await analytics.persistPendingNow()
        #expect(Self.savedBytes(root) == nil)
    }

    /// A deferred write that outlives its directory (a test's temporary
    /// root, or `~/.config/rv` removed while rvd ran) does not create it.
    @Test func aDeferredWriteDoesNotRecreateARemovedDirectory() async throws {
        let root = try temporaryConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = Self.coordinator(root, persistDelay: .seconds(600))
        await analytics.recordDecision(.deny)
        try FileManager.default.removeItem(at: root)
        await analytics.persistPendingNow()
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    @Test func aZeroDelayWritesEveryDecision() async throws {
        let root = try temporaryConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = Self.coordinator(root, persistDelay: .zero)
        await analytics.recordDecision(.deny)
        #expect(try Self.saved(root).denyCount == 1)
        await analytics.recordDecision(.deny)
        #expect(try Self.saved(root).denyCount == 2)
    }
}
