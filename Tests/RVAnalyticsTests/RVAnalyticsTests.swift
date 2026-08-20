import Foundation
import Testing
@testable import RVAnalytics

@Suite("AnalyticsPreferences")
struct AnalyticsPreferencesTests {
    @Test func missingConfigDefaultsEnabled() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let prefs = AnalyticsPreferences.load(from: paths)
        #expect(prefs.isEnabled == true)
    }

    @Test func configCanDisable() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let json = #"{"analytics":{"enabled":false}}"#
        try Data(json.utf8).write(to: paths.configFile)
        let prefs = AnalyticsPreferences.load(from: paths)
        #expect(prefs.isEnabled == false)
    }
}

@Suite("AnalyticsIdentity")
struct AnalyticsIdentityTests {
    @Test func persistsStableID() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let first = try AnalyticsIdentity.loadOrCreate(in: paths, newID: { "id-one" })
        let second = try AnalyticsIdentity.loadOrCreate(in: paths, newID: { "id-two" })
        #expect(first.distinctID == "id-one")
        #expect(second.distinctID == "id-one")
    }
}

@Suite("AnalyticsBootstrap")
struct AnalyticsBootstrapTests {
    @Test func optedOutDoesNotCreateIdentity() throws {
        let fakeHome = try temporaryConfigRoot()
        let configDir = fakeHome
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(#"{"analytics":{"enabled":false}}"#.utf8).write(
            to: configDir.appendingPathComponent("config.json", isDirectory: false)
        )
        let result = AnalyticsBootstrap.live(
            productVersion: "1.0.0",
            environment: ["HOME": fakeHome.path]
        )
        #expect(result == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: configDir.appendingPathComponent("analytics-id").path
            ) == false
        )
    }
}

@Suite("PostHogSink")
struct PostHogSinkTests {
    @Test func encodesBatchWithoutCommandFields() throws {
        let payload = AnalyticsPayload(
            event: AnalyticsPayload.dailyActiveEvent,
            distinctID: "abc",
            properties: [
                "rv_version": .string("1.0.0"),
                "allow_count": .int(3),
                "enabled_packs": .strings(["core.git", "core.filesystem"]),
            ]
        )
        let data = try PostHogSink.encodeBatch(apiKey: "phc_test", payload: payload)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(root?["api_key"] as? String == "phc_test")
        let batch = root?["batch"] as? [[String: Any]]
        #expect(batch?.count == 1)
        let properties = batch?.first?["properties"] as? [String: Any]
        #expect(properties?["distinct_id"] as? String == "abc")
        #expect(properties?["allow_count"] as? Int == 3)
        #expect(properties?.keys.contains("command") == false)
        #expect(properties?.keys.contains("path") == false)
    }

    @Test func emptyAPIKeyIsNoOp() async {
        let poster = RecordingHTTPPoster()
        let sink = PostHogSink(apiKey: "", poster: poster)
        let delivered = await sink.capture(
            AnalyticsPayload(event: "install", distinctID: "x")
        )
        let count = await poster.count
        #expect(delivered == false)
        #expect(count == 0)
    }
}

@Suite("AnalyticsCoordinator")
struct AnalyticsCoordinatorTests {
    @Test func installOnceAndDailyFlush() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .optOutDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
        )
        await coordinator.captureInstall(hosts: ["grok": "wired", "pi": "pending"])
        await coordinator.recordDecision(.allow)
        await coordinator.recordDecision(.deny)
        await coordinator.noteEnabledPacks(["core.git", "core.filesystem"])
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        await coordinator.recordDecision(.allow)
        await coordinator.captureInstall(hosts: ["grok": "wired"])
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 21))

        let events = await sink.events
        #expect(events.map(\.event) == [
            AnalyticsPayload.installEvent,
            AnalyticsPayload.dailyActiveEvent,
            AnalyticsPayload.dailyActiveEvent,
        ])
        let daily = events[1]
        #expect(daily.properties["allow_count"] == .int(1))
        #expect(daily.properties["deny_count"] == .int(1))
        #expect(daily.properties["host_grok"] == .string("wired"))
        #expect(daily.properties["enabled_packs"] == .strings(["core.filesystem", "core.git"]))
        #expect(events[2].properties["allow_count"] == .int(1))
    }

    @Test func failedInstallDoesNotMarkSent() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let sink = FailingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .optOutDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
        )
        await coordinator.captureInstall(hosts: ["grok": "wired"])
        #expect(FileManager.default.fileExists(atPath: paths.installSentFile.path) == false)

        let okSink = RecordingAnalyticsSink()
        let retry = AnalyticsCoordinator(
            paths: paths,
            preferences: .optOutDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: okSink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
        )
        await retry.captureInstall(hosts: ["grok": "wired"])
        let events = await okSink.events
        #expect(events.map(\.event) == [AnalyticsPayload.installEvent])
        #expect(FileManager.default.fileExists(atPath: paths.installSentFile.path))
    }

    @Test func failedFlushKeepsCounters() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let sink = FailingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .optOutDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
        )
        await coordinator.recordDecision(.allow)
        await coordinator.recordDecision(.deny)
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))

        let okSink = RecordingAnalyticsSink()
        let next = AnalyticsCoordinator(
            paths: paths,
            preferences: .optOutDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: okSink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
        )
        await next.flushDailyIfNeeded(now: day(2026, 8, 21))
        let events = await okSink.events
        #expect(events.count == 1)
        #expect(events[0].properties["allow_count"] == .int(1))
        #expect(events[0].properties["deny_count"] == .int(1))
    }

    @Test func disabledSkipsCapture() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: AnalyticsPreferences(isEnabled: false),
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
        )
        await coordinator.captureInstall(hosts: [:])
        await coordinator.recordDecision(.deny)
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        let events = await sink.events
        #expect(events.isEmpty)
    }
}

@Suite("AnalyticsNotice")
struct AnalyticsNoticeTests {
    @Test func silentByDefault() {
        #expect(AnalyticsNotice.setupLine() == nil)
        #expect(AnalyticsNotice.doctorLine(isEnabled: true) == nil)
    }
}

actor RecordingAnalyticsSink: AnalyticsSink {
    private(set) var events: [AnalyticsPayload] = []

    func capture(_ payload: AnalyticsPayload) async -> Bool {
        events.append(payload)
        return true
    }
}

actor FailingAnalyticsSink: AnalyticsSink {
    func capture(_ payload: AnalyticsPayload) async -> Bool {
        _ = payload
        return false
    }
}

actor RecordingHTTPPoster: HTTPPosting {
    private(set) var count = 0

    func post(url: URL, body: Data, contentType: String) async throws {
        _ = url
        _ = body
        _ = contentType
        count += 1
    }
}

private func temporaryConfigRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-analytics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.year = year
    components.month = month
    components.day = day
    return components.date ?? Date(timeIntervalSince1970: 0)
}
