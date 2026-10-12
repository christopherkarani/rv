import Foundation
import Synchronization
import Testing
@testable import RVIsolation

final class SentRequests: Sendable {
    let items = Mutex<[[String]]>([])
}

/// L4: the production URLSession transport against a public echo service.
/// Opt in with `RV_LIVE_NETWORK=1`.
@Suite("SecretGatewayLive", .enabled(if: ProcessInfo.processInfo.environment["RV_LIVE_NETWORK"] == "1"))
struct SecretGatewayLiveTests {
    @Test func realUpstreamReceivesTheValueAndTheEchoComesBackScrubbed() throws {
        let secret = "rv-live-test-\(UUID().uuidString)"
        let audit = AuditRecords()
        let sent = SentRequests()
        let live = SecretUpstreamTransport.urlSession
        let recording = SecretUpstreamTransport { request, sink in
            sent.items.withLock { $0.append(request.headers.map { "\($0.name): \($0.value)" } + [request.url.absoluteString]) }
            live.send(request, sink)
        }
        let gateway = SecretGateway(transport: recording) { record in audit.items.withLock { $0.append(record) } }
        defer { gateway.stop() }
        let port = try gateway.start().get()
        let placeholder = SecretPlaceholder.mint(prefix: "")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "ECHO_TOKEN", prefix: "", value: try #require(SecretValue(secret)),
            upstream: try #require(URL(string: "https://postman-echo.com")), fingerprint: nil, runtime: nil))

        let response = try gatewayExchange(port: port,
            "GET /s/ECHO_TOKEN/get?token=\(placeholder.text) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Authorization: Bearer \(placeholder.text)\r\nAccept-Encoding: gzip\r\n\r\n")
        #expect(response.status == 200)
        #expect(response.body.contains(secret) == false)
        #expect(response.body.contains("Bearer \(placeholder.text)"))
        #expect(response.body.contains("\"token\": \"\(placeholder.text)\"")
            || response.body.contains("\"token\":\"\(placeholder.text)\""))
        #expect(audit.items.withLock { $0.first?.status } == 200)
        let wire = try #require(sent.items.withLock { $0.first })
        #expect(wire.contains("Authorization: Bearer \(secret)"))
        #expect(wire.contains("https://postman-echo.com/get?token=\(secret)"))
        #expect(wire.joined().contains("rvph_") == false)
    }

    @Test func redirectsAreNotFollowed() throws {
        let audit = AuditRecords()
        let gateway = SecretGateway { record in audit.items.withLock { $0.append(record) } }
        defer { gateway.stop() }
        let port = try gateway.start().get()
        let placeholder = SecretPlaceholder.mint(prefix: "")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "ECHO_TOKEN", prefix: "", value: try #require(SecretValue("redirect-secret")),
            upstream: try #require(URL(string: "https://postman-echo.com")), fingerprint: nil, runtime: nil))
        let response = try gatewayExchange(port: port,
            "GET /s/ECHO_TOKEN/redirect-to?url=https%3A%2F%2Fexample.com&status_code=302 HTTP/1.1\r\n"
                + "Authorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(response.status == 302)
        #expect(response.headers["location"] == "https://example.com")
    }
}
