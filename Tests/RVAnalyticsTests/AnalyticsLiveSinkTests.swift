import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RVAnalytics

@Suite("URLSessionHTTPPoster", .serialized)
struct URLSessionHTTPPosterTests {
    @Test func twoHundredIsAccepted() async throws {
        let server = try LoopbackHTTPServer.start(statusCode: 200)
        defer { server.stop() }
        let poster = URLSessionHTTPPoster()
        try await poster.post(
            to: server.origin.appendingPathComponent("batch/"),
            body: Data(#"{"ok":true}"#.utf8),
            contentType: "application/json"
        )
    }

    @Test func nonTwoHundredThrowsStatus() async throws {
        let server = try LoopbackHTTPServer.start(statusCode: 500)
        defer { server.stop() }
        let poster = URLSessionHTTPPoster()
        do {
            try await poster.post(
                to: server.origin.appendingPathComponent("batch/"),
                body: Data("{}".utf8),
                contentType: "application/json"
            )
            Issue.record("loopback 500 must throw")
        } catch let error as AnalyticsTransportError {
            #expect(error == .httpStatus(500))
        }
    }

    @Test func closedPortThrowsWithoutLeavingLoopback() async throws {
        let server = try LoopbackHTTPServer.start(statusCode: 200)
        let url = server.origin
        server.stop()
        await #expect(throws: (any Error).self) {
            try await URLSessionHTTPPoster().post(
                to: url,
                body: Data("{}".utf8),
                contentType: "application/json"
            )
        }
    }
}

@Suite("Live sink without ingest", .serialized)
struct AnalyticsLiveSinkTests {
    @Test func bootstrapInstallHitsLoopbackPoster() async throws {
        let server = try LoopbackHTTPServer.start(statusCode: 200)
        defer { server.stop() }
        let fakeHome = try temporaryConfigRoot()
        let coordinator = try #require(
            AnalyticsBootstrap.makeLive(
                productVersion: "1.0.0",
                environment: [
                    "HOME": fakeHome.path,
                    "RV_POSTHOG_API_KEY": "phc_test_local_only",
                    "RV_POSTHOG_HOST": server.origin.absoluteString,
                ]
            )
        )
        await coordinator.captureInstall(hosts: ["pi": "wired"])
        let installSent = fakeHome
            .appendingPathComponent(".config/rv/analytics-install-sent")
        #expect(FileManager.default.fileExists(atPath: installSent.path))
    }

    @Test func loopbackFiveHundredKeepsInstallUnsent() async throws {
        let server = try LoopbackHTTPServer.start(statusCode: 500)
        defer { server.stop() }
        let fakeHome = try temporaryConfigRoot()
        let coordinator = try #require(
            AnalyticsBootstrap.makeLive(
                productVersion: "1.0.0",
                environment: [
                    "HOME": fakeHome.path,
                    "RV_POSTHOG_API_KEY": "phc_test_local_only",
                    "RV_POSTHOG_HOST": server.origin.absoluteString,
                ]
            )
        )
        await coordinator.captureInstall(hosts: ["pi": "wired"])
        let installSent = fakeHome
            .appendingPathComponent(".config/rv/analytics-install-sent")
        #expect(FileManager.default.fileExists(atPath: installSent.path) == false)
    }

    @Test func sinkAcceptedOnLoopbackDoesNotIncludeCommand() async throws {
        let server = try LoopbackHTTPServer.start(statusCode: 201)
        defer { server.stop() }
        let sink = PostHogSink(
            apiKey: "phc_test_local_only",
            host: server.origin,
            poster: URLSessionHTTPPoster()
        )
        let payload = AnalyticsPayload(
            event: AnalyticsPayload.dailyActiveEvent,
            distinctID: "anon",
            properties: [
                "rv_version": .string("1.0.0"),
                "allow_count": .int(0),
            ]
        )
        expectNoCommandOrPath(payload)
        #expect(await sink.capture(payload) == .accepted)
    }
}
