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

/// Loopback HTTP/1.1 upstream, one thread per connection. `/big` answers
/// `bigBytes` x's with a Content-Length; any other path answers `ok:<path>`.
private final class LoopbackUpstream: @unchecked Sendable {
    static let bigBytes = 64 << 20
    let port: Int
    private let listenFD: Int32

    init() throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        try #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, listen(fd, 128) == 0, named == 0 else {
            close(fd)
            throw LoopbackUpstreamError.unavailable
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: name.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            Thread.detachNewThread { Self.serve(client) }
        }
    }

    private static func serve(_ client: Int32) {
        defer { close(client) }
        var request: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 65_536, String(decoding: request, as: UTF8.self).contains("\r\n\r\n") == false {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            request += buffer.prefix(n)
        }
        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        if path.hasSuffix("/big") {
            guard write(client, Array("HTTP/1.1 200 OK\r\nContent-Length: \(bigBytes)\r\nConnection: close\r\n\r\n".utf8))
            else { return }
            let block = [UInt8](repeating: UInt8(ascii: "x"), count: 65_536)
            var sent = 0
            while sent < bigBytes, write(client, block) { sent += block.count }
        } else {
            let body = Array("ok:\(path)".utf8)
            _ = write(client, Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                + body)
        }
    }

    private static func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base + written, raw.count - written, flags)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }
}

private enum LoopbackUpstreamError: Error { case unavailable }

private final class Answers: Sendable {
    let items = Mutex<[Int: String]>([:])
}

/// Collects what one `send` delivered.
private final class CollectingSink: SecretResponseSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var ended: String?

    func head(status: Int, headers: [(name: String, value: String)]) {}
    func body(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data)
        return true
    }
    func finish() { end("finished") }
    func fail(_ reason: String) { end("failed: \(reason)") }

    private func end(_ how: String) {
        lock.lock()
        defer { lock.unlock() }
        ended = how
    }

    var result: (body: String, ended: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: bytes, as: UTF8.self), ended)
    }
}

/// The production transport, pointed at the loopback upstream: the gateway
/// only forwards to https, so the request is rewritten on its way out.
private func loopbackTransport(_ transport: URLSessionStreamingTransport, port: Int) -> SecretUpstreamTransport {
    SecretUpstreamTransport { request, sink in
        var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        components?.host = "127.0.0.1"
        components?.port = port
        guard let url = components?.url else { return sink.fail("unrewritable url") }
        transport.send(
            SecretUpstreamRequest(method: request.method, url: url, headers: request.headers, body: request.body),
            sink: sink)
    }
}

private func connectGateway(_ port: Int) throws -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    try #require(fd >= 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if connected != 0 { close(fd) }
    try #require(connected == 0)
    return fd
}

private struct GatewayUnderTest {
    let gateway: SecretGateway
    let port: Int
    let placeholder: SecretPlaceholder

    init(upstreamPort: Int, clientSendTimeout: Int? = nil) throws {
        gateway = SecretGateway(
            transport: loopbackTransport(URLSessionStreamingTransport(), port: upstreamPort),
            peers: .fixed(.member), audit: { _ in true })
        if let clientSendTimeout { gateway.clientSendTimeout = clientSendTimeout }
        port = try gateway.start().get()
        placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", value: try #require(SecretValue("sk-live-REAL-0123456789")),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: "R1",
            surfaces: [.header], processGroup: testProcessGroup))
    }

    func request(_ path: String) -> String {
        "GET /s/OPENAI_API_KEY\(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n"
    }
}

@Suite("URLSession streaming transport")
struct URLSessionStreamingTransportTests {
    /// Concurrent first sends on a fresh transport: each request gets its
    /// own answer, none hangs. A lazily made session was built once per
    /// racing caller, and their task numbers collided in one sink table.
    @Test(.timeLimit(.minutes(1)))
    func concurrentFirstSendsEachGetTheirOwnBody() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let count = 16
        let transport = URLSessionStreamingTransport()
        let sinks = (0..<count).map { _ in CollectingSink() }
        let start = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        for index in 0..<count {
            let sink = sinks[index]
            let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/r\(index)"))
            done.enter()
            Thread.detachNewThread {
                start.wait()
                transport.send(SecretUpstreamRequest(method: "GET", url: url, headers: [], body: Data()), sink: sink)
                done.leave()
            }
        }
        for _ in 0..<count { start.signal() }
        let finished = done.wait(timeout: .now() + 15) == .success
        #expect(finished, "some sends never returned")
        for (index, sink) in sinks.enumerated() {
            let result = sink.result
            #expect(result.ended == "finished", "request \(index): \(result.ended ?? "still waiting")")
            #expect(result.body == "ok:/r\(index)", "request \(index) got \(result.body.prefix(40))")
        }
    }

    /// A client that sends a request and never reads holds only its own
    /// answer: another request through the same gateway is still answered.
    @Test(.timeLimit(.minutes(1)))
    func aClientThatDoesNotReadDoesNotStallTheOthers() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        defer { under.gateway.stop() }
        let stalled = try connectGateway(under.port)
        defer { close(stalled) }
        #expect(GatewaySocket.writeAll(stalled, Array(under.request("/big").utf8)))
        // Long enough for the big answer to fill every buffer on its way.
        Thread.sleep(forTimeInterval: 1)
        let started = Date()
        let other = try gatewayExchange(port: under.port, under.request("/small"))
        #expect(other.status == 200)
        #expect(other.body == "ok:/v1/small")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// Past the send timeout the stalled client's connection is closed, and
    /// what it can still read is cut short: never a complete chunked body.
    @Test(.timeLimit(.minutes(1)))
    func aClientThatDoesNotReadIsCutOffShort() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port, clientSendTimeout: 1)
        defer { under.gateway.stop() }
        let stalled = try connectGateway(under.port)
        defer { close(stalled) }
        #expect(GatewaySocket.writeAll(stalled, Array(under.request("/big").utf8)))
        Thread.sleep(forTimeInterval: 4)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(stalled, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var last = 0
        while true {
            last = buffer.withUnsafeMutableBytes { read(stalled, $0.baseAddress, $0.count) }
            if last <= 0 { break }
            received += buffer.prefix(last)
        }
        #expect(last == 0, "the connection was not closed")
        let head = String(decoding: received.prefix(512), as: UTF8.self).lowercased()
        #expect(head.hasPrefix("http/1.1 200"))
        #expect(head.contains("transfer-encoding: chunked"))
        #expect(received.count < LoopbackUpstream.bigBytes)
        #expect(Array(received.suffix(5)) != Array("0\r\n\r\n".utf8), "a cut-off answer ended like a complete one")
    }

    /// A client that reads, slowly, gets the whole of a large answer: the
    /// upstream is paused while the client falls behind and resumed as it
    /// catches up, with nothing lost or repeated.
    @Test(.timeLimit(.minutes(1)))
    func aSlowReaderGetsTheWholeLargeAnswer() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        defer { under.gateway.stop() }
        let client = try connectGateway(under.port)
        defer { close(client) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #expect(GatewaySocket.writeAll(client, Array(under.request("/big").utf8)))
        var received: [UInt8] = []
        received.reserveCapacity(LoopbackUpstream.bigBytes + (1 << 20))
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var last = 0
        while true {
            last = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if last <= 0 { break }
            received += buffer.prefix(last)
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(last == 0)
        let separator = Array("\r\n\r\n".utf8)
        try #require(received.count > 4096)
        let headEnd = try #require((0...(4096 - separator.count)).first {
            Array(received[$0..<($0 + separator.count)]) == separator
        })
        #expect(String(decoding: received[..<headEnd], as: UTF8.self).lowercased().contains("transfer-encoding: chunked"))
        var cursor = headEnd + separator.count
        var body = 0
        var ended = false
        while cursor < received.count, let lineEnd = received[cursor...].firstIndex(of: 13) {
            let size = try #require(Int(String(decoding: received[cursor..<lineEnd], as: UTF8.self), radix: 16))
            cursor = lineEnd + 2 + size + 2
            if size == 0 {
                ended = true
                break
            }
            body += size
        }
        #expect(ended)
        #expect(body == LoopbackUpstream.bigBytes)
    }

    #if os(macOS)
    /// Every thread of GCD's shared pool held: requests through the gateway
    /// are still served and answered. Its connection handlers ran on that
    /// pool, so none of them could start. In a child process, so the held
    /// threads never reach the other tests.
    @Test(.timeLimit(.minutes(1)))
    func theGatewayAnswersWhileTheSharedPoolIsHeld() async {
        await #expect(processExitsWith: .success) {
            try URLSessionStreamingTransportTests.burstWhileThePoolIsHeld()
        }
    }

    static func burstWhileThePoolIsHeld() throws {
        let held = DispatchSemaphore(value: 0)
        for _ in 0..<256 { DispatchQueue.global().async { held.wait() } }
        Thread.sleep(forTimeInterval: 0.5)
        let upstream = try LoopbackUpstream()
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        let count = 16
        let answers = Answers()
        let done = DispatchGroup()
        for index in 0..<count {
            let request = under.request("/b\(index)")
            let port = under.port
            done.enter()
            Thread.detachNewThread {
                let response = try? gatewayExchange(port: port, request)
                answers.items.withLock { $0[index] = response.map { "\($0.status) \($0.body)" } ?? "none" }
                done.leave()
            }
        }
        _ = done.wait(timeout: .now() + 20)
        let got = answers.items.withLock { $0 }
        let wrong = (0..<count).filter { got[$0] != "200 ok:/v1/b\($0)" }
        if wrong.isEmpty == false {
            FileHandle.standardError.write(Data("unanswered or wrong: \(wrong.map { "\($0)=\(got[$0] ?? "none")" })\n".utf8))
            exit(1)
        }
        exit(0)
    }
    #endif
}
