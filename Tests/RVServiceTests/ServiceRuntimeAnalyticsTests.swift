import Foundation
import RVAnalytics
import RVDomain
import RVIPC
import RVPolicy
import Testing
@testable import RVService

struct ServiceRuntimeAnalyticsTests {
    @Test func evaluateSnapshotsEnabledPackIDsBeforeAsyncWork() async throws {
        let fixture = try makeAnalyticsFixture()
        defer { fixture.removeDirectories() }

        // Generic IPC evaluate stays denied (.agent); the daemon evaluates
        // in process and still snapshots analytics.
        let response = await fixture.runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git status"),
                enabledPacks: dayOnePackIDs
            )
        )
        guard case .allow = response.result.decision else {
            Issue.record("expected git status to allow")
            return
        }

        guard let daily = await flushUntilDailyEvent(
            coordinator: fixture.coordinator,
            sink: fixture.sink,
            containsCoreGit: true
        ) else {
            return
        }
        #expect(enabledPackIDs(in: daily)?.contains("core.git") == true)
        #expect(daily.properties.keys.contains("command") == false)
        #expect(daily.properties.keys.contains("path") == false)

        let events = await fixture.sink.events
        #expect(events.isEmpty == false)
        #expect(events.allSatisfy { payload in
            payload.properties.keys.contains("command") == false
                && payload.properties.keys.contains("path") == false
        })
    }

    @Test func setPackEnabledDeniedLeavesAnalyticsPackSnapshot() async throws {
        let fixture = try makeAnalyticsFixture()
        defer { fixture.removeDirectories() }

        let evaluated = await fixture.runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git status"),
                enabledPacks: dayOnePackIDs
            )
        )
        guard case .allow = evaluated.result.decision else {
            Issue.record("expected git status to allow")
            return
        }
        guard await flushUntilDailyEvent(
            coordinator: fixture.coordinator,
            sink: fixture.sink,
            containsCoreGit: true
        ) != nil else {
            return
        }
        let eventsBeforeDisable = await fixture.sink.events.count

        // Owner-mutation dispatch stays denied: no pack changes, and the
        // analytics snapshot keeps reporting the day-one set.
        let disable = await fixture.runtime.dispatch(
            IPCRequest(
                method: .setPackEnabled(
                    SetPackEnabledParams(id: .coreGit, enabled: false)
                )
            )
        )
        #expect(disable.result == .error(.authorizationDenied))

        guard let daily = await flushUntilDailyEvent(
            coordinator: fixture.coordinator,
            sink: fixture.sink,
            afterEventCount: eventsBeforeDisable,
            containsCoreGit: true
        ) else {
            return
        }
        #expect(enabledPackIDs(in: daily)?.contains("core.git") == true)
        #expect(daily.properties.keys.contains("command") == false)
        #expect(daily.properties.keys.contains("path") == false)
    }

    @Test func hookEvaluateRecordsDecisionAnalyticsWithoutCommandText() async throws {
        let fixture = try makeAnalyticsFixture()
        defer { fixture.removeDirectories() }

        let stdin = try grokHookFixture("deny-git-reset-hard.json")
        let response = await fixture.runtime.dispatch(
            IPCRequest(
                method: .hookEvaluate(
                    HookEvaluateParams(
                        host: .grok,
                        stdin: stdin,
                        clientSemver: ProtocolVersion.serviceSemver
                    )
                )
            ),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("expected hookEvaluate reply")
            return
        }
        #expect(reply.exitCode == 0)
        #expect(reply.stdout.contains("\"decision\":\"deny\""))

        // The deny is counted on rvd's analytics task; the hook-local spool
        // drain may note the packs and flush a day before it lands.
        guard let daily = await flushUntilDailyEvent(
            coordinator: fixture.coordinator,
            sink: fixture.sink,
            containsCoreGit: true,
            requiring: { $0.properties["deny_count"] == .int(1) }
        ) else {
            return
        }
        let events = await fixture.sink.events
        #expect(events.contains { payload in
            payload.properties["deny_count"] == .int(1)
        })
        #expect(enabledPackIDs(in: daily)?.contains("core.git") == true)
        #expect(daily.properties.keys.contains("command") == false)
        #expect(daily.properties.keys.contains("path") == false)
        #expect(events.allSatisfy { payload in
            payload.properties.keys.contains("command") == false
                && payload.properties.keys.contains("path") == false
        })
    }
}

actor RecordingAnalyticsSink: AnalyticsSink {
    private(set) var events: [AnalyticsPayload] = []

    func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery {
        events.append(payload)
        return .accepted
    }
}

private struct AnalyticsFixture: Sendable {
    let runtime: ServiceRuntime
    let coordinator: AnalyticsCoordinator
    let sink: RecordingAnalyticsSink
    let directories: [URL]

    func removeDirectories() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private func makeAnalyticsFixture() throws -> AnalyticsFixture {
    let homeURL = try isolatedHomeDirectory()
    let home = try #require(HomeDirectory(validating: homeURL.path))
    let allowOnceURL = try isolatedAllowOnceDirectory()
    let analyticsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-service-analytics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: analyticsURL, withIntermediateDirectories: true)

    let sink = RecordingAnalyticsSink()
    let coordinator = AnalyticsCoordinator(
        paths: AnalyticsPaths(configDirectory: analyticsURL),
        preferences: .enabledByDefault,
        identity: AnalyticsIdentity(distinctID: "user-1"),
        sink: sink,
        productVersion: "1.0.0",
        platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354")
    )
    let runtime = hookTestRuntime(
        home: home,
        allowOnceDirectory: allowOnceURL,
        analytics: coordinator
    )
    return AnalyticsFixture(
        runtime: runtime,
        coordinator: coordinator,
        sink: sink,
        directories: [homeURL, allowOnceURL, analyticsURL]
    )
}

/// Flushes one new day at a time until a daily event with (or without)
/// core.git that also satisfies `requiring` arrives, for up to 60 s: on a
/// starved pool rvd's analytics task, and the hook-local spool drain that
/// notes the packs and flushes too, can run late and in either order.
private func flushUntilDailyEvent(
    coordinator: AnalyticsCoordinator,
    sink: RecordingAnalyticsSink,
    afterEventCount: Int = 0,
    containsCoreGit: Bool,
    requiring: @escaping @Sendable (AnalyticsPayload) -> Bool = { _ in true }
) async -> AnalyticsPayload? {
    let deadline = ContinuousClock.now + .seconds(60)
    var offset = 0
    while ContinuousClock.now < deadline {
        await coordinator.flushDailyIfNeeded(now: analyticsDay(offset: offset))
        offset += 1
        let events = await sink.events
        if let event = events.dropFirst(afterEventCount).last(where: { payload in
            guard payload.event == AnalyticsPayload.dailyActiveEvent,
                  let enabledPacks = enabledPackIDs(in: payload)
            else {
                return false
            }
            return enabledPacks.contains("core.git") == containsCoreGit && requiring(payload)
        }) {
            return event
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for daily analytics enabled_packs")
    return nil
}

private func enabledPackIDs(in payload: AnalyticsPayload) -> [String]? {
    guard let value = payload.properties["enabled_packs"] else {
        return nil
    }
    guard case .strings(let ids) = value else {
        return nil
    }
    return ids
}

private func analyticsDay(offset: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.year = 2099
    components.month = 1
    components.day = 1
    let start = components.date ?? Date(timeIntervalSince1970: 0)
    return Calendar(identifier: .gregorian)
        .date(byAdding: .day, value: offset, to: start) ?? start
}

private func grokHookFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVHooksTests/Fixtures/grok/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

/// rvd's idle and replaced-binary exits call `exit(0)`, which would drop
/// decision counts still waiting for the coordinator's deferred write.
struct RVDExitAnalyticsTests {
    @Test func anOrderlyExitWritesPendingCounts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-service-analytics-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AnalyticsPaths(configDirectory: root)
        let coordinator = AnalyticsCoordinator(
            paths: paths,
            preferences: .enabledByDefault,
            identity: AnalyticsIdentity(distinctID: "user-1"),
            sink: RecordingAnalyticsSink(),
            productVersion: "1.0.0",
            platform: PlatformSnapshot(osVersion: "26.0.0", osBuild: "25A354"),
            persistDelay: .seconds(600)
        )
        await coordinator.recordDecision(.deny)
        await coordinator.recordDecision(.allow)
        #expect(FileManager.default.fileExists(atPath: paths.countersFile.path) == false)

        // Blocks its thread as the exit closure does, waiting for a Task
        // that needs a cooperative thread: block a thread of its own, never
        // one of the pool's (a detached Task is still on the pool).
        await offPool { RVDLifecycle.persistAnalytics(coordinator, wait: .seconds(30)) }

        let text = try String(contentsOf: paths.countersFile, encoding: .utf8)
        #expect(text.contains(#""denyCount":1"#))
        #expect(text.contains(#""allowCount":1"#))
    }

    @Test func noAnalyticsIsANoOp() {
        RVDLifecycle.persistAnalytics(nil)
    }
}
