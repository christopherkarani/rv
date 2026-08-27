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

        let response = await fixture.runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git status"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .evaluate = response.result else {
            Issue.record("expected evaluate reply")
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

    @Test func setPackEnabledRefreshesAnalyticsPackSnapshot() async throws {
        let fixture = try makeAnalyticsFixture()
        defer { fixture.removeDirectories() }

        let evaluate = await fixture.runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git status"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .evaluate = evaluate.result else {
            Issue.record("expected evaluate reply")
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

        let disable = await fixture.runtime.dispatch(
            IPCRequest(
                method: .setPackEnabled(
                    SetPackEnabledParams(id: .coreGit, enabled: false)
                )
            )
        )
        guard case .setPackEnabled(let reply) = disable.result else {
            Issue.record("expected setPackEnabled reply")
            return
        }
        #expect(reply.pack.id == .coreGit)
        #expect(reply.pack.enabled == false)

        guard let daily = await flushUntilDailyEvent(
            coordinator: fixture.coordinator,
            sink: fixture.sink,
            afterEventCount: eventsBeforeDisable,
            containsCoreGit: false
        ) else {
            return
        }
        #expect(enabledPackIDs(in: daily)?.contains("core.git") == false)
        #expect(daily.properties.keys.contains("command") == false)
        #expect(daily.properties.keys.contains("path") == false)
    }
}

actor RecordingAnalyticsSink: AnalyticsSink {
    private(set) var events: [AnalyticsPayload] = []

    func capture(_ payload: AnalyticsPayload) async -> Bool {
        events.append(payload)
        return true
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
        preferences: .optOutDefault,
        identity: AnalyticsIdentity(distinctID: "user-1"),
        sink: sink,
        productVersion: "1.0.0",
        platform: PlatformSnapshot(macosVersion: "26.0.0", macosBuild: "25A354")
    )
    let runtime = ServiceRuntime(
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

private func flushUntilDailyEvent(
    coordinator: AnalyticsCoordinator,
    sink: RecordingAnalyticsSink,
    afterEventCount: Int = 0,
    containsCoreGit: Bool
) async -> AnalyticsPayload? {
    for offset in 0..<64 {
        await coordinator.flushDailyIfNeeded(now: analyticsDay(offset: offset))
        let events = await sink.events
        if let event = events.dropFirst(afterEventCount).last(where: { payload in
            guard payload.event == AnalyticsPayload.dailyActiveEvent,
                  let enabledPacks = enabledPackIDs(in: payload)
            else {
                return false
            }
            return enabledPacks.contains("core.git") == containsCoreGit
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
