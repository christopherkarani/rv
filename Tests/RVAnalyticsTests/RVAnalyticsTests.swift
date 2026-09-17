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

    @Test func configCanEnableExplicitly() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data(#"{"analytics":{"enabled":true}}"#.utf8).write(to: paths.configFile)
        #expect(AnalyticsPreferences.load(from: paths).isEnabled == true)
    }

    @Test func invalidJSONDefaultsEnabled() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data("{".utf8).write(to: paths.configFile)
        #expect(AnalyticsPreferences.load(from: paths).isEnabled == true)
    }

    @Test func missingAnalyticsObjectDefaultsEnabled() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data(#"{"other":true}"#.utf8).write(to: paths.configFile)
        #expect(AnalyticsPreferences.load(from: paths).isEnabled == true)
    }

    @Test func analyticsValueNotObjectDefaultsEnabled() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data(#"{"analytics":"nope"}"#.utf8).write(to: paths.configFile)
        #expect(AnalyticsPreferences.load(from: paths).isEnabled == true)
    }

    @Test func enabledNonBoolDefaultsEnabled() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data(#"{"analytics":{"enabled":"yes"}}"#.utf8).write(to: paths.configFile)
        #expect(AnalyticsPreferences.load(from: paths).isEnabled == true)
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

    @Test func whitespaceFileCreatesNewID() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try Data("  \n".utf8).write(to: paths.identityFile)
        let identity = try AnalyticsIdentity.loadOrCreate(in: paths, newID: { "fresh-id" })
        #expect(identity.distinctID == "fresh-id")
    }

    @Test func invalidUTF8CreatesNewID() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE]).write(to: paths.identityFile)
        let identity = try AnalyticsIdentity.loadOrCreate(in: paths, newID: { "utf8-id" })
        #expect(identity.distinctID == "utf8-id")
    }

    @Test func defaultGeneratorPersistsNonEmptyID() throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let identity = try AnalyticsIdentity.loadOrCreate(in: paths)
        #expect(identity.distinctID.isEmpty == false)
        #expect(UUID(uuidString: identity.distinctID) != nil)
        let again = try AnalyticsIdentity.loadOrCreate(in: paths, newID: { "must-not-replace" })
        #expect(again.distinctID == identity.distinctID)
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
        let result = AnalyticsBootstrap.makeLive(
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

    @Test func missingHomeReturnsNil() {
        #expect(
            AnalyticsBootstrap.makeLive(productVersion: "1.0.0", environment: [:]) == nil
        )
    }

    @Test func emptyHomeReturnsNil() {
        #expect(
            AnalyticsBootstrap.makeLive(
                productVersion: "1.0.0",
                environment: ["HOME": ""]
            ) == nil
        )
    }

    @Test func identityCreateFailureReturnsNil() throws {
        let fakeHome = try temporaryConfigRoot()
        try Data("not-a-directory".utf8).write(
            to: fakeHome.appendingPathComponent(".config", isDirectory: false)
        )
        #expect(
            AnalyticsBootstrap.makeLive(
                productVersion: "1.0.0",
                environment: ["HOME": fakeHome.path]
            ) == nil
        )
    }

    @Test func enabledFakeSinkCapturesWithoutCommandFields() async throws {
        let fakeHome = try temporaryConfigRoot()
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsBootstrap.makeLive(
            productVersion: "1.2.3",
            sink: sink,
            environment: ["HOME": fakeHome.path]
        )
        let live = try #require(coordinator)
        #expect(await live.isEnabled)
        await live.captureInstall(hosts: ["pi": "wired"])
        await live.recordDecision(.indeterminate)
        await live.noteEnabledPacks(["core.git"])
        await live.flushDailyIfNeeded(now: day(2026, 8, 22))
        let events = await sink.events
        #expect(events.map(\.event) == [
            AnalyticsPayload.installEvent,
            AnalyticsPayload.dailyActiveEvent,
        ])
        #expect(events[0].properties["rv_version"] == .string("1.2.3"))
        #expect(events[1].properties["indeterminate_count"] == .int(1))
        for payload in events {
            expectNoCommandOrPath(payload)
        }
    }

    @Test func emptyAPIKeyUsesNoOpSink() async throws {
        let fakeHome = try temporaryConfigRoot()
        let coordinator = try #require(
            AnalyticsBootstrap.makeLive(
                productVersion: "1.0.0",
                environment: ["HOME": fakeHome.path]
            )
        )
        await coordinator.captureInstall(hosts: ["pi": "wired"])
        let installSent = fakeHome
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("analytics-install-sent", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: installSent.path) == false)
    }

    @Test func apiKeyConstructsLiveSinkWithoutSending() throws {
        let fakeHome = try temporaryConfigRoot()
        let coordinator = AnalyticsBootstrap.makeLive(
            productVersion: "1.0.0",
            environment: [
                "HOME": fakeHome.path,
                "RV_POSTHOG_API_KEY": "phc_test_local_only",
                "RV_POSTHOG_HOST": "http://127.0.0.1:9",
            ]
        )
        #expect(coordinator != nil)
        #expect(FileManager.default.fileExists(atPath: fakeHome
            .appendingPathComponent(".config/rv/analytics-id").path))
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
        #expect(properties?.keys.contains("secret") == false)
    }

    @Test func encodesBoolProperty() throws {
        let payload = AnalyticsPayload(
            event: "install",
            distinctID: "abc",
            properties: ["ok": .bool(true)]
        )
        let data = try PostHogSink.encodeBatch(apiKey: "phc_test", payload: payload)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let batch = root?["batch"] as? [[String: Any]]
        let properties = batch?.first?["properties"] as? [String: Any]
        #expect(properties?["ok"] as? Bool == true)
    }

    @Test func acceptedPosterDoesNotPhoneHome() async {
        let poster = RecordingHTTPPoster()
        let sink = PostHogSink(apiKey: "phc_test", poster: poster)
        let delivered = await sink.capture(
            AnalyticsPayload(event: AnalyticsPayload.installEvent, distinctID: "x")
        )
        let count = await poster.count
        let url = await poster.lastURL
        let type = await poster.lastContentType
        #expect(delivered == .accepted)
        #expect(count == 1)
        #expect(type == "application/json")
        #expect(url?.absoluteString.hasSuffix("batch/") == true)
        #expect(url?.host == AnalyticsCredentials.defaultHost.host)
    }

    @Test func throwingPosterDrops() async {
        let sink = PostHogSink(apiKey: "phc_test", poster: ThrowingHTTPPoster())
        let delivered = await sink.capture(
            AnalyticsPayload(event: "install", distinctID: "x")
        )
        #expect(delivered == .dropped)
    }

    @Test func noOpSinkDrops() async {
        let delivered = await NoOpAnalyticsSink().capture(
            AnalyticsPayload(event: "install", distinctID: "x")
        )
        #expect(delivered == .dropped)
    }

    @Test func emptyAPIKeyIsNoOp() async {
        let poster = RecordingHTTPPoster()
        let sink = PostHogSink(apiKey: "", poster: poster)
        let delivered = await sink.capture(
            AnalyticsPayload(event: "install", distinctID: "x")
        )
        let count = await poster.count
        #expect(delivered == .dropped)
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
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
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
        #expect(events[0].properties["macos_version"] == .string("26.0.0"))
        #expect(events[0].properties["macos_build"] == .string("25A354"))
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
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.captureInstall(hosts: ["grok": "wired"])
        #expect(FileManager.default.fileExists(atPath: paths.installSentFile.path) == false)

        let okSink = RecordingAnalyticsSink()
        let retry = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: okSink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
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
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.recordDecision(.allow)
        await coordinator.recordDecision(.deny)
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))

        let okSink = RecordingAnalyticsSink()
        let next = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: okSink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
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
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.captureInstall(hosts: [:])
        await coordinator.recordDecision(.deny)
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        await coordinator.noteEnabledPacks(["core.git"])
        await coordinator.noteHosts(["pi": "wired"])
        let events = await sink.events
        #expect(events.isEmpty)
        #expect(FileManager.default.fileExists(atPath: paths.countersFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.hostsFile.path) == false)
    }

    @Test func indeterminateIsCountedOnFlush() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        #expect(await coordinator.isEnabled)
        await coordinator.recordDecision(.indeterminate)
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        let events = await sink.events
        #expect(events[0].properties["indeterminate_count"] == .int(1))
        expectNoCommandOrPath(events[0])
    }

    @Test func alreadySentInstallOnlyNotesHosts() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data("1".utf8).write(to: paths.installSentFile, options: .atomic)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.captureInstall(hosts: ["cursor": "wired"])
        var events = await sink.events
        #expect(events.isEmpty)
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        events = await sink.events
        #expect(events.map(\.event) == [AnalyticsPayload.dailyActiveEvent])
        #expect(events[0].properties["host_cursor"] == .string("wired"))
    }

    @Test func loadsHostsWhenCountersOmitThem() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data(#"{"pi":"pending"}"#.utf8).write(to: paths.hostsFile)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        let events = await sink.events
        #expect(events[0].properties["host_pi"] == .string("pending"))
    }

    @Test func corruptCountersAndHostsStartEmpty() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        try Data("not-json".utf8).write(to: paths.countersFile)
        try Data("[1]".utf8).write(to: paths.hostsFile)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        let events = await sink.events
        #expect(events[0].properties["allow_count"] == .int(0))
        #expect(events[0].properties.keys.contains(where: { $0.hasPrefix("host_") }) == false)
    }

    @Test func countersHostsWinOverHostsFile() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let state = AnalyticsCounterState(
            allowCount: 4,
            denyCount: 0,
            indeterminateCount: 0,
            lastFlushDay: "",
            enabledPackIDs: ["core.git"],
            hosts: ["pi": "wired"]
        )
        try JSONEncoder().encode(state).write(to: paths.countersFile)
        try Data(#"{"pi":"pending"}"#.utf8).write(to: paths.hostsFile)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        let events = await sink.events
        #expect(events[0].properties["allow_count"] == .int(4))
        #expect(events[0].properties["host_pi"] == .string("wired"))
        #expect(events[0].properties["enabled_packs"] == .strings(["core.git"]))
    }

    @Test func emptyHostsPersistWithoutCommandFields() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.noteHosts([:])
        #expect(FileManager.default.fileExists(atPath: paths.hostsFile.path))
        await coordinator.flushDailyIfNeeded(now: day(2026, 8, 20))
        let events = await sink.events
        expectNoCommandOrPath(events[0])
        #expect(events[0].properties.keys.contains(where: { $0.hasPrefix("host_") }) == false)
    }

    @Test func flushWithoutNowStampsLocalDayOnce() async throws {
        let root = try temporaryConfigRoot()
        let paths = AnalyticsPaths(configDirectory: root)
        let sink = RecordingAnalyticsSink()
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: sink,
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
        )
        await coordinator.flushDailyIfNeeded()
        await coordinator.flushDailyIfNeeded()
        let events = await sink.events
        #expect(events.map(\.event) == [AnalyticsPayload.dailyActiveEvent])
    }
}

@Suite("AnalyticsNotice")
struct AnalyticsNoticeTests {
    @Test func silentByDefault() {
        #expect(AnalyticsNotice.setupLine() == nil)
        #expect(AnalyticsNotice.doctorLine(isEnabled: true) == nil)
        #expect(AnalyticsNotice.doctorLine(isEnabled: false) == nil)
    }
}
