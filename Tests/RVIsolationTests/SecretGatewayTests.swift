#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// Upstream stand-in: records what the gateway forwarded and answers with a
/// canned response delivered in the given chunks.
final class RecordingUpstream: Sendable {
    struct Seen: Sendable {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data
    }

    let seen = Mutex<[Seen]>([])
    let status: Int
    let headers: [(name: String, value: String)]
    let chunks: [Data]

    init(status: Int = 200, headers: [(name: String, value: String)] = [], chunks: [Data] = []) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
    }

    var transport: SecretUpstreamTransport {
        SecretUpstreamTransport { request, sink in
            var headers: [String: String] = [:]
            for header in request.headers { headers[header.name.lowercased()] = header.value }
            self.seen.withLock {
                $0.append(Seen(
                    method: request.method, url: request.url.absoluteString, headers: headers, body: request.body))
            }
            sink.head(status: self.status, headers: self.headers)
            for chunk in self.chunks where sink.body(chunk) == false { break }
            sink.finish()
        }
    }

    var requests: [Seen] { seen.withLock { $0 } }
}

struct GatewayExchange {
    var status: Int
    var headers: [String: String]
    var body: String
}

/// One raw HTTP/1.1 exchange against 127.0.0.1:`port`; reads to EOF.
func gatewayExchange(port: Int, _ request: String) throws -> GatewayExchange {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    try #require(fd >= 0)
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(connected == 0)
    let bytes = Array(request.utf8)
    var written = 0
    while written < bytes.count {
        let n = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base + written, raw.count - written)
        }
        try #require(n > 0)
        written += n
    }
    var response: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        response += buffer.prefix(n)
    }
    let text = String(decoding: response, as: UTF8.self)
    var parts = text.components(separatedBy: "\r\n\r\n")
    // A 100 Continue interim response precedes the real head.
    while let first = parts.first, first.hasPrefix("HTTP/1.1 100") { parts.removeFirst() }
    let headLines = (parts.first ?? "").components(separatedBy: "\r\n")
    let status = Int(headLines.first?.split(separator: " ").dropFirst().first ?? "") ?? -1
    var headers: [String: String] = [:]
    for line in headLines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    var body = parts.dropFirst().joined(separator: "\r\n\r\n")
    if headers["transfer-encoding"] == "chunked" { body = dechunk(body) }
    return GatewayExchange(status: status, headers: headers, body: body)
}

private func dechunk(_ text: String) -> String {
    var bytes = Array(text.utf8)[...]
    var output: [UInt8] = []
    while let lineEnd = bytes.firstIndex(of: 13) {
        let size = Int(String(decoding: bytes[bytes.startIndex..<lineEnd], as: UTF8.self), radix: 16) ?? 0
        bytes = bytes[(lineEnd + 2)...]
        if size == 0 { break }
        output += bytes.prefix(size)
        bytes = bytes.dropFirst(size + 2)
    }
    return String(decoding: output, as: UTF8.self)
}

final class AuditRecords: Sendable {
    let items = Mutex<[SecretUseRecord]>([])
}

@Suite("SecretGateway")
struct SecretGatewayTests {
    private func harness(
        upstream: RecordingUpstream, value: String = "sk-live-REAL-0123456789", prefix: String = "sk-",
        audit: AuditRecords
    ) throws -> (SecretGateway, Int, SecretPlaceholder) {
        let gateway = SecretGateway(transport: upstream.transport) { record in audit.items.withLock { $0.append(record) } }
        let port = try gateway.start().get()
        let placeholder = SecretPlaceholder.mint(prefix: prefix)
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: prefix, value: try #require(SecretValue(value)),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: "R1"))
        return (gateway, port, placeholder)
    }

    @Test func forwardsTheRealValueOnlyUpstreamAndScrubsTheEcho() throws {
        let secret = "sk-live-REAL-0123456789"
        let upstream = RecordingUpstream(
            status: 200,
            headers: [("Content-Type", "application/json"), ("X-Echo", "key=\(secret)"), ("Content-Length", "99")],
            chunks: [Data("{\"auth\":\"Bearer sk-live-RE".utf8), Data("AL-0123456789\",\"ok\":true}".utf8)])
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try harness(upstream: upstream, audit: audit)
        defer { gateway.stop() }

        let response = try gatewayExchange(port: port,
            "POST /s/OPENAI_API_KEY/chat/completions?stream=false HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Authorization: Bearer \(placeholder.text)\r\nContent-Type: application/json\r\n"
                + "Accept-Encoding: gzip\r\nContent-Length: 11\r\n\r\n{\"a\":\"b\"}\r\n")

        let seen = try #require(upstream.requests.first)
        #expect(seen.method == "POST")
        #expect(seen.url == "https://api.example.com/v1/chat/completions?stream=false")
        #expect(seen.headers["authorization"] == "Bearer \(secret)")
        #expect(seen.headers["accept-encoding"] == nil)
        #expect(seen.headers["host"] == nil)
        #expect(seen.body == Data("{\"a\":\"b\"}\r\n".utf8))

        #expect(response.status == 200)
        #expect(response.body == "{\"auth\":\"Bearer \(placeholder.text)\",\"ok\":true}")
        #expect(response.headers["x-echo"] == "key=\(placeholder.text)")
        #expect(response.headers["content-length"] == nil)
        #expect(response.body.contains(secret) == false)

        let record = try #require(audit.items.withLock { $0.first })
        #expect(record.allowed)
        #expect(record.secret == "OPENAI_API_KEY")
        #expect(record.runtime == "R1")
        #expect(record.path == "/s/OPENAI_API_KEY/chat/completions")
        #expect(record.upstreamHost == "api.example.com")
        #expect(record.status == 200)
        #expect(record.fingerprint == "abcd")
    }

    @Test func refusesUnknownAndRevokedPlaceholdersWithoutCallingUpstream() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try harness(upstream: upstream, audit: audit)
        defer { gateway.stop() }

        let stranger = try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(SecretPlaceholder.mint(prefix: "sk-").text)\r\n\r\n")
        #expect(stranger.status == 403)
        let bare = try gatewayExchange(port: port, "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer sk-x\r\n\r\n")
        #expect(bare.status == 401)
        let unrouted = try gatewayExchange(port: port, "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(unrouted.status == 404)

        gateway.revoke([placeholder])
        let revoked = try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(revoked.status == 403)
        #expect(upstream.requests.isEmpty)
        #expect(audit.items.withLock { $0.allSatisfy { $0.allowed == false } && $0.count == 4 })
    }

    @Test func acceptsChunkedBodiesAndExpectContinue() throws {
        let upstream = RecordingUpstream(status: 201, chunks: [Data("created".utf8)])
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try harness(upstream: upstream, audit: audit)
        defer { gateway.stop() }
        let response = try gatewayExchange(port: port,
            "PUT /s/OPENAI_API_KEY/files HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n"
                + "Expect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n")
        #expect(response.status == 201)
        #expect(response.body == "created")
        #expect(upstream.requests.first?.body == Data("Wikipedia".utf8))
        #expect(upstream.requests.first?.headers["expect"] == nil)
    }

    @Test func headResponsesCarryNoBodyFraming() throws {
        let upstream = RecordingUpstream(status: 200, headers: [("ETag", "x")])
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try harness(upstream: upstream, audit: audit)
        defer { gateway.stop() }
        let response = try gatewayExchange(port: port,
            "HEAD /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(response.status == 200)
        #expect(response.headers["transfer-encoding"] == nil)
        #expect(response.body.isEmpty)
    }

    @Test func oversizedBodiesAreRefused() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try harness(upstream: upstream, audit: audit)
        defer { gateway.stop() }
        let response = try gatewayExchange(port: port,
            "POST /s/OPENAI_API_KEY/x HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n"
                + "Content-Length: \(SecretGateway.maximumBodyBytes + 1)\r\n\r\n")
        #expect(response.status == 413)
        #expect(upstream.requests.isEmpty)
    }

    @Test func chunkedSizeThatOverflowsTheTotalIsRefusedAndTheGatewayStaysUp() throws {
        #expect(Int("7fffffffffffffff", radix: 16) == Int.max)
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try harness(upstream: upstream, audit: audit)
        defer { gateway.stop() }
        let response = try gatewayExchange(port: port,
            "POST /s/OPENAI_API_KEY/x HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n1\r\nA\r\n7fffffffffffffff\r\n")
        #expect(response.status == 413)
        #expect(upstream.requests.isEmpty)
        let follow = try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(follow.status == 200)
        #expect(upstream.requests.count == 1)
    }

    @Test func chunkedReadRejectsASizeBeforeItCanOverflowOrPassTheLimit() throws {
        #expect(try readChunkedPayload("1\r\nA\r\n7fffffffffffffff\r\n", limit: 8) == nil)
        #expect(try readChunkedPayload("5\r\nABCDE\r\n0\r\n\r\n", limit: 4) == nil)
        #expect(try readChunkedPayload("3\r\nABC\r\n2\r\nDE\r\n0\r\n\r\n", limit: 4) == nil)
        #expect(try readChunkedPayload("3\r\nABC\r\n1\r\nD\r\n0\r\n\r\n", limit: 4) == Data("ABCD".utf8))
        #expect(try readChunkedPayload("4\r\nWXYZ\r\n0\r\n\r\n", limit: 4) == Data("WXYZ".utf8))
    }

    @Test func aSecondStartReusesThePublishedPort() throws {
        let gateway = SecretGateway(transport: RecordingUpstream().transport) { _ in }
        let first = try gateway.start().get()
        let second = try gateway.start().get()
        defer { gateway.stop() }
        #expect(first == second)
        #expect(try gatewayExchange(port: first, "GET /nope HTTP/1.1\r\n\r\n").status == 404)
    }

    @Test func overlappingStartsPublishOneListenerAndStopClosesIt() throws {
        let overlap = StartOverlap()
        let gateway = SecretGateway(transport: RecordingUpstream().transport) { _ in }
        gateway.beforeListenerPublish = { overlap.waitForPeer() }
        let ports = Mutex<[Int]>([])
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if case .success(let port) = gateway.start() {
                    ports.withLock { $0.append(port) }
                }
            }
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        let seen = ports.withLock { $0 }
        #expect(seen.count == 2)
        #expect(Set(seen).count == 1)
        let port = try #require(seen.first)
        #expect(try gatewayExchange(port: port, "GET /nope HTTP/1.1\r\n\r\n").status == 404)
        gateway.beforeListenerPublish = nil
        gateway.stop()
        #expect(portAccepts(port) == false)
        let restarted = try gateway.start().get()
        #expect(try gatewayExchange(port: restarted, "GET /nope HTTP/1.1\r\n\r\n").status == 404)
        gateway.stop()
        #expect(portAccepts(restarted) == false)
    }
}

/// Two `start` calls block until both have passed the fast path.
private final class StartOverlap: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = 0
    private let release = DispatchSemaphore(value: 0)

    func waitForPeer() {
        lock.lock()
        arrived += 1
        let turn = arrived
        lock.unlock()
        if turn == 1 {
            _ = release.wait(timeout: .now() + 2)
        } else {
            release.signal()
        }
    }
}

private func readChunkedPayload(_ payload: String, limit: Int) throws -> Data? {
    var fds = [Int32](repeating: -1, count: 2)
    let opened = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
        guard let base = buffer.baseAddress else { return -1 }
        #if canImport(Darwin)
        return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        #else
        return socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, base)
        #endif
    }
    try #require(opened == 0)
    defer {
        for fd in fds where fd >= 0 { close(fd) }
    }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let bytes = Array(payload.utf8)
    let wrote = bytes.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return write(fds[0], base, raw.count)
    }
    try #require(wrote == bytes.count)
    close(fds[0])
    fds[0] = -1
    return GatewaySocket.Reader(fd: fds[1]).readChunked(limit: limit)
}

private func portAccepts(_ port: Int) -> Bool {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return connected == 0
}
