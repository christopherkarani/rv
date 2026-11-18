import Foundation
import RVAnalytics
import RVPresentation
import Synchronization
import Testing
@testable import RVCLI

final class RecordingInstallAnalytics: InstallAnalyticsCapturing, Sendable {
    private let box = Mutex<[[String: String]]>([])

    var captures: [[String: String]] { box.withLock { $0 } }

    func captureInstall(hosts: [String: String]) {
        box.withLock { $0.append(hosts) }
    }
}

final class InstallRecordingSink: AnalyticsSink, Sendable {
    private let box = Mutex<[AnalyticsPayload]>([])

    var events: [AnalyticsPayload] { box.withLock { $0 } }

    func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery {
        box.withLock { $0.append(payload) }
        return .accepted
    }
}

/// Install analytics wired the way `rv setup` wires it, with a recording sink
/// in place of PostHog so nothing leaves the machine.
private func liveInstallAnalytics(home: URL, sink: InstallRecordingSink) -> BlockingInstallAnalytics {
    let homePath = home.path
    // A generous timeout: the wait ends as soon as the capture does, and a
    // starved CI runner must not turn a slow capture into a missing event.
    return BlockingInstallAnalytics(timeoutSeconds: 60) {
        AnalyticsBootstrap.makeLive(
            productVersion: "1.0.0",
            sink: sink,
            environment: ["HOME": homePath]
        )
    }
}

private func analyticsPaths(_ layout: OwnedPaths) -> AnalyticsPaths {
    AnalyticsPaths(configDirectory: URL(fileURLWithPath: layout.configDirectory, isDirectory: true))
}

@Test func installAnalyticsHosts_mapsSlotKinds() {
    let slots = SetupSlotSnapshot(
        grok: .wired,
        pi: .occupied,
        openCode: .skipped,
        wrote: [.grok]
    )
    #expect(InstallAnalyticsHosts.from(slots) == [
        "grok": "wired",
        "pi": "occupied",
        "opencode": "skipped",
        "claude": "skipped",
        "openclaw": "skipped",
            "hermes": "skipped",
            "codex": "skipped",
            "cursor": "skipped",
            "antigravity": "skipped",
            "muse": "skipped",
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
            "pi": "skipped",
            "opencode": "skipped",
            "claude": "skipped",
            "openclaw": "skipped",
            "hermes": "skipped",
            "codex": "skipped",
            "cursor": "skipped",
            "antigravity": "skipped",
            "muse": "skipped",
        ]])
        let paths = AnalyticsPaths(
            configDirectory: URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        )
        #expect(FileManager.default.fileExists(atPath: paths.identityFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.hostsFile.path) == false)
    }
}

@Test func setup_withoutAnalyticsOptIn_sendsNoInstallEventAndMintsNoIdentity() throws {
    let sink = InstallRecordingSink()
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl, installAnalytics: liveInstallAnalytics(home: home, sink: sink))
        )
        #expect(outcome.exitCode == 0)
        let paths = analyticsPaths(layout)
        for artifact in [paths.identityFile, paths.countersFile, paths.installSentFile, paths.hostsFile] {
            #expect(FileManager.default.fileExists(atPath: artifact.path) == false)
        }
    }
    #expect(sink.events.isEmpty)
}

@Test func setup_liveInstallAnalyticsWithoutOptIn_writesNoAnalyticsFiles() throws {
    // The production wiring, with no PostHog key in the environment (so no network).
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let analytics = BlockingInstallAnalytics.live(home: testHomeDirectory(home.path), environment: [:])
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl, installAnalytics: analytics)
        )
        #expect(outcome.exitCode == 0)
        let paths = analyticsPaths(layout)
        #expect(FileManager.default.fileExists(atPath: paths.identityFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.hostsFile.path) == false)
    }
}

@Test func setup_withAnalyticsOptIn_sendsInstallEvent() throws {
    let sink = InstallRecordingSink()
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let paths = analyticsPaths(layout)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"analytics":{"enabled":true}}"#.utf8).write(to: paths.configFile)
        let outcome = SetupRun.setup(
            env(home: home, launchctl: launchctl, installAnalytics: liveInstallAnalytics(home: home, sink: sink))
        )
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: paths.identityFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.installSentFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.hostsFile.path))
    }
    #expect(sink.events.map(\.event) == [AnalyticsPayload.installEvent])
}
