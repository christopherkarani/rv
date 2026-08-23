import Foundation
import RVAnalytics
import RVPresentation
import Testing
@testable import RVCLI

final class RecordingInstallAnalytics: InstallAnalyticsCapturing, @unchecked Sendable {
    private(set) var captures: [[String: String]] = []

    func captureInstall(hosts: [String: String]) {
        captures.append(hosts)
    }
}

final class StalledAnalyticsSink: AnalyticsSink {
    func capture(_: AnalyticsPayload) async -> Bool {
        try? await Task.sleep(for: .seconds(30))
        return true
    }
}

func stalledInstallCoordinator(configDirectory: URL) -> AnalyticsCoordinator {
    AnalyticsCoordinator(
        paths: AnalyticsPaths(configDirectory: configDirectory),
        preferences: .optOutDefault,
        identity: AnalyticsIdentity(distinctID: "test-install"),
        sink: StalledAnalyticsSink(),
        productVersion: "0.0.0",
        platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
    )
}

@Test func installAnalyticsHosts_mapsSlotKinds() {
    let slots = SetupSlotSnapshot(
        grok: .wired,
        pi: .occupied,
        openCode: .pending,
        wrote: [.grok]
    )
    #expect(InstallAnalyticsHosts.from(slots) == [
        "grok": "wired",
        "pi": "occupied",
        "opencode": "pending",
    ])
}

@Test func blockingInstallAnalytics_nilCoordinatorReturnsImmediately() {
    let analytics = BlockingInstallAnalytics(makeCoordinator: { nil })
    analytics.captureInstall(hosts: ["grok": "wired"])
}

@Test func blockingInstallAnalytics_stalledSinkReturnsWithinDefaultBudget() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-analytics-stall-\(UUID().uuidString)", isDirectory: true)
    let coordinator = stalledInstallCoordinator(configDirectory: root)
    let analytics = BlockingInstallAnalytics { coordinator }
    let start = ContinuousClock.now
    analytics.captureInstall(hosts: ["grok": "wired"])
    #expect(start.duration(to: .now) < .seconds(5))
}

@Test func setupFlow_uninstallRecordsNoInstallAnalytics() throws {
    try withTempHome { home, layout, launchctl in
        let analytics = RecordingInstallAnalytics()
        let environment = env(home: home, launchctl: launchctl, installAnalytics: analytics)
        let outcome = SetupFlow(makeEnvironment: { environment })
            .run(SetupIntent(kind: .uninstall, appearance: .robot))
        #expect(outcome.exitCode == 0)
        #expect(analytics.captures.isEmpty)
    }
}

@Test func setupFlow_recordsInstallAnalyticsThroughTheDoor_withoutWritingIdentity() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let analytics = RecordingInstallAnalytics()
        let environment = env(home: home, launchctl: launchctl, installAnalytics: analytics)
        let outcome = SetupFlow(makeEnvironment: { environment })
            .run(SetupIntent(kind: .install, appearance: .robot))
        #expect(outcome.exitCode == 0)
        #expect(analytics.captures == [[
            "grok": "wired",
            "pi": "pending",
            "opencode": "pending",
        ]])
        let paths = AnalyticsPaths(
            configDirectory: URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        )
        #expect(FileManager.default.fileExists(atPath: paths.identityFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.hostsFile.path) == false)
    }
}
