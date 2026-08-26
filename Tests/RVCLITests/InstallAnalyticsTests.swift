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
        "claude": "pending",
        "openclaw": "pending",
        "hermes": "pending",
    ])
}

@Test func blockingInstallAnalytics_nilCoordinatorReturnsImmediately() {
    let analytics = BlockingInstallAnalytics(timeoutSeconds: 10, makeCoordinator: { nil })
    analytics.captureInstall(hosts: ["grok": "wired"])
}

@Test func setup_recordsInstallAnalyticsWithoutWritingIdentity() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let analytics = RecordingInstallAnalytics()
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl, installAnalytics: analytics)
        )
        #expect(outcome.exitCode == 0)
        #expect(analytics.captures == [[
            "grok": "wired",
            "pi": "pending",
            "opencode": "pending",
            "claude": "pending",
            "openclaw": "pending",
            "hermes": "pending",
        ]])
        let paths = AnalyticsPaths(
            configDirectory: URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        )
        #expect(FileManager.default.fileExists(atPath: paths.identityFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.hostsFile.path) == false)
    }
}
