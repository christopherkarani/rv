#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import RVIsolation

/// Loopback HTTP/1.1 upstream, one thread per connection, counting the
/// requests it receives by method and path. `/big` answers `bigBytes` x's
/// with a Content-Length, `/bytes/N` answers N x's, and `/slow/N/ms`
/// answers N x's in 64 KiB blocks `ms` milliseconds apart. A path with
/// `/ka/` answers `ok:<path>` and keeps the connection open for the next
/// request; one with `/drop/` closes it unanswered. `/auth/<kind>` answers
/// 401 with a `basic`, `digest` or `bearer` challenge, or `none`. Any other
/// path answers `ok:<path>`. A request body is read before the answer.
private final class LoopbackUpstream: @unchecked Sendable {
    static let bigBytes = 64 << 20
    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var hits: [String: Int] = [:]
    private var accepted = 0

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

    /// How many requests arrived with this method and path.
    func hits(_ method: String, _ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hits["\(method) \(path)"] ?? 0
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
            lock.lock()
            accepted += 1
            lock.unlock()
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    /// Connections accepted so far.
    var connections: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    /// Requests are counted when their head arrives, before any body: a
    /// request sent again without its body is counted too.
    private func serve(_ client: Int32) {
        defer { close(client) }
        var pending: [UInt8] = []
        while let request = Self.readHead(client, &pending) {
            let (method, path, length) = request
            lock.lock()
            hits["\(method) \(path)", default: 0] += 1
            lock.unlock()
            guard Self.skip(length, of: client, &pending), path.contains("/drop/") == false else { return }
            guard path.contains("/ka/") else { return answer(client, path) }
            let body = Array("ok:\(path)".utf8)
            let head = Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            guard Self.write(client, method == "HEAD" ? head : head + body) else { return }
        }
    }

    private static func readHead(_ fd: Int32, _ pending: inout [UInt8]) -> (String, String, Int)? {
        let separator = Array("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if pending.count >= separator.count, let end = (0...(pending.count - separator.count)).first(where: {
                Array(pending[$0..<($0 + separator.count)]) == separator
            }) {
                let lines = String(decoding: pending[..<end], as: UTF8.self).components(separatedBy: "\r\n")
                pending.removeFirst(end + separator.count)
                let parts = (lines.first ?? "").split(separator: " ").map(String.init)
                let length = lines.dropFirst().compactMap { line -> Int? in
                    let field = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return field.count == 2 && field[0].lowercased() == "content-length" ? Int(field[1]) : nil
                }.first ?? 0
                return (parts.first ?? "?", parts.dropFirst().first ?? "/", length)
            }
            guard pending.count < 65_536 else { return nil }
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return nil }
            pending += buffer.prefix(n)
        }
    }

    private static func skip(_ length: Int, of fd: Int32, _ pending: inout [UInt8]) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while pending.count < length {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return false }
            pending += buffer.prefix(n)
        }
        pending.removeFirst(length)
        return true
    }

    private func answer(_ client: Int32, _ path: String) {
        let segments = path.split(separator: "/").map(String.init)
        if let at = segments.firstIndex(of: "auth"), at + 1 < segments.count {
            let challenge = [
                "basic": "WWW-Authenticate: Basic realm=\"rv\"\r\n",
                "digest": "WWW-Authenticate: Digest realm=\"rv\", nonce=\"0123abcd\", qop=\"auth\"\r\n",
                "bearer": "WWW-Authenticate: Bearer realm=\"rv\"\r\n",
            ][segments[at + 1]] ?? ""
            let body = Array("denied".utf8)
            _ = Self.write(client, Array(
                "HTTP/1.1 401 Unauthorized\r\n\(challenge)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    .utf8) + body)
        } else if let at = segments.firstIndex(of: "interim"), at + 1 < segments.count,
            let code = Int(segments[at + 1])
        {
            let body = Array("the final answer".utf8)
            _ = Self.write(client, Array(
                ("HTTP/1.1 \(code) Interim\r\nLink: </style.css>; rel=preload\r\n\r\n"
                    + "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8) + body)
        } else if path.hasSuffix("/big") {
            Self.stream(client, bytes: Self.bigBytes, pause: 0)
        } else if let at = segments.firstIndex(of: "bytes"), at + 1 < segments.count, let size = Int(segments[at + 1]) {
            Self.stream(client, bytes: size, pause: 0)
        } else if let at = segments.firstIndex(of: "slow"), at + 2 < segments.count,
            let size = Int(segments[at + 1]), let pause = Int(segments[at + 2])
        {
            Self.stream(client, bytes: size, pause: pause)
        } else {
            let body = Array("ok:\(path)".utf8)
            _ = Self.write(
                client, Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
        }
    }

    private static func stream(_ client: Int32, bytes: Int, pause milliseconds: Int) {
        guard write(client, Array("HTTP/1.1 200 OK\r\nContent-Length: \(bytes)\r\nConnection: close\r\n\r\n".utf8))
        else { return }
        let block = [UInt8](repeating: UInt8(ascii: "x"), count: 65_536)
        var sent = 0
        while sent < bytes {
            let next = min(block.count, bytes - sent)
            guard write(client, Array(block.prefix(next))) else { return }
            sent += next
            if milliseconds > 0 { Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000) }
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

/// What a reader thread has read, and whether it should go on.
private final class Trickle: Sendable {
    let going = Atomic<Bool>(true)
    let received = Mutex<[UInt8]>([])
}

/// Collects what one `send` delivered.
private final class CollectingSink: SecretResponseSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var ended: String?
    private var status: Int?

    func head(status: Int, headers: [(name: String, value: String)]) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
    }
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

    /// The status the transport handed on, nil before any.
    var headStatus: Int? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

/// Counts what one `send` delivered, stalling on its first body until the gate opens.
private final class GatedSink: SecretResponseSink, @unchecked Sendable {
    private let gate: DispatchSemaphore
    private let lock = NSLock()
    private var bytes = 0
    private var opened = false
    private var ended: String?

    init(_ gate: DispatchSemaphore) {
        self.gate = gate
    }

    func head(status: Int, headers: [(name: String, value: String)]) {}
    func body(_ data: Data) -> Bool {
        lock.lock()
        let first = opened == false
        opened = true
        bytes += data.count
        lock.unlock()
        if first { gate.wait() }
        return true
    }
    func finish() { end("finished") }
    func fail(_ reason: String) { end("failed: \(reason)") }

    private func end(_ how: String) {
        lock.lock()
        ended = how
        lock.unlock()
    }

    var result: (bytes: Int, ended: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, ended)
    }
}

/// Polls `condition` every 10 ms until it holds or `seconds` pass.
private func eventually(within seconds: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while condition() == false {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// Never resumed: an exchange for the budget to name, with nothing in flight.
private let idleSession = URLSession(configuration: .ephemeral)

private func idleExchange(_ budget: URLSessionStreamingBudget) -> URLSessionStreamingExchange {
    let task = idleSession.dataTask(with: URL(fileURLWithPath: "/dev/null"))
    return URLSessionStreamingExchange(task: task, budget: budget, handoff: nil)
}

extension URLSessionStreamingBudget.Admission {
    fileprivate var taken: Bool {
        if case .taken = self { return true }
        return false
    }

    fileprivate var refused: Bool {
        if case .refused = self { return true }
        return false
    }

    fileprivate var victim: URLSessionStreamingExchange? {
        if case .evict(let victim) = self { return victim }
        return nil
    }
}

/// The plain answer the gateway wrote to `fd` before closing it, or what
/// arrived before a read timed out.
private func plainAnswer(_ fd: Int32) -> String {
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var received: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        received += buffer.prefix(n)
    }
    return String(decoding: received, as: UTF8.self)
}

private func readable(_ fd: Int32) -> Bool {
    var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&state, 1, 0) == 1
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

/// A small `receiveBuffer` keeps what the kernel holds for a client that is
/// not reading well under the transport's marks.
private func connectGateway(_ port: Int, receiveBuffer: Int32? = nil) throws -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    try #require(fd >= 0)
    #if canImport(Darwin)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
    if var size = receiveBuffer {
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
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
    let transport: URLSessionStreamingTransport
    let port: Int
    let placeholder: SecretPlaceholder

    init(
        upstreamPort: Int, limits: URLSessionStreamingTransport.Limits = .init(), clientSendTimeout: Int? = nil,
        headDeadline: TimeInterval? = nil, bodyDeadline: TimeInterval? = nil
    ) throws {
        transport = URLSessionStreamingTransport(limits: limits)
        gateway = SecretGateway(
            transport: loopbackTransport(transport, port: upstreamPort),
            peers: .fixed(.member), audit: { _ in true })
        if let clientSendTimeout { gateway.clientSendTimeout = clientSendTimeout }
        if let headDeadline { gateway.requestHeadDeadline = headDeadline }
        if let bodyDeadline { gateway.requestBodyDeadline = bodyDeadline }
        port = try gateway.start().get()
        placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", value: try #require(SecretValue("sk-live-REAL-0123456789")),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: "R1",
            surfaces: [.header], processGroup: testProcessGroup))
    }

    func request(_ path: String, method: String = "GET", body: String = "") -> String {
        let length = method == "GET" ? "" : "Content-Length: \(body.utf8.count)\r\n"
        return "\(method) /s/OPENAI_API_KEY\(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer \(placeholder.text)\r\n\(length)\r\n\(body)"
    }
}

/// What a client read of one chunked answer, until the gateway closed the
/// connection or a read timed out.
private struct ChunkedAnswer {
    var head = ""
    /// Body bytes, whole chunks and any part of a last cut-off one.
    var body = 0
    /// The zero-length chunk that ends a complete body arrived.
    var ended = false
    /// The gateway closed the connection; false when a read timed out.
    var closed = false
    var bodyIsAllX = true

    /// Waits `pause` before the first read and `perRead` after each one.
    init(reading fd: Int32, pause: TimeInterval = 0, perRead: TimeInterval = 0) throws {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 {
                closed = n == 0
                break
            }
            received += buffer.prefix(n)
            if perRead > 0 { Thread.sleep(forTimeInterval: perRead) }
        }
        let separator = Array("\r\n\r\n".utf8)
        try #require(received.count >= separator.count)
        let headEnd = try #require((0...min(4096, received.count - separator.count)).first {
            Array(received[$0..<($0 + separator.count)]) == separator
        })
        head = String(decoding: received[..<headEnd], as: UTF8.self).lowercased()
        var cursor = headEnd + separator.count
        while cursor < received.count, let lineEnd = received[cursor...].firstIndex(of: 13) {
            guard let size = Int(String(decoding: received[cursor..<lineEnd], as: UTF8.self), radix: 16) else { break }
            if size == 0 {
                ended = true
                break
            }
            let start = min(lineEnd + 2, received.count)
            let stop = min(start + size, received.count)
            body += stop - start
            if received[start..<stop].contains(where: { $0 != UInt8(ascii: "x") }) { bodyIsAllX = false }
            cursor = stop + 2
        }
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
    /// Its request gives back what it held: no bytes wait, and its session
    /// is invalidated, never kept for another request.
    @Test(.timeLimit(.minutes(1)))
    func aClientThatDoesNotReadIsCutOffShort() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port, clientSendTimeout: 1)
        defer { under.gateway.stop() }
        let stalled = try connectGateway(under.port)
        defer { close(stalled) }
        #expect(GatewaySocket.writeAll(stalled, Array(under.request("/big").utf8)))
        // Read only once the request has been cut off and its session let go.
        let counts = { under.transport.sessionCounts }
        #expect(eventually(within: 40) { counts().made == 1 && counts().live == 0 }, "\(counts())")
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
        #expect(under.transport.budget.waiting == 0)
        #expect(upstream.hits("GET", "/v1/big") == 1)
    }

    /// A client that takes in 16 KiB every 0.05 s, so that every write moves
    /// well inside the 2 s send timeout, is cut off once it has taken in
    /// less than the minimum (here 1 MiB) over a window of the gateway
    /// waiting to write to it. The send timeout alone never cuts it: Darwin
    /// wakes a blocked write only once much of its buffer is free, so a
    /// reader slower than this, such as 8 KiB every 0.25 s, already let a
    /// write block past 2 s. Its upstream
    /// request is cancelled, everything it held is given back, and what it
    /// still reads is cut short, with no terminator.
    @Test(.timeLimit(.minutes(1)))
    func aClientTakingInTooLittleIsCutOff() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port, clientSendTimeout: 2)
        defer { under.gateway.stop() }
        under.gateway.clientMinimumBytes = 1 << 20
        let client = try connectGateway(under.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        #expect(GatewaySocket.writeAll(client, Array(under.request("/big").utf8)))
        let trickle = Trickle()
        let stopped = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while trickle.going.load(ordering: .relaxed) {
                let n = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                trickle.received.withLock { $0 += buffer.prefix(n) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            stopped.signal()
        }
        let counts = { under.transport.sessionCounts }
        let released = eventually(within: 20) {
            counts().made == 1 && counts().live == 0 && under.transport.budget.waiting == 0
        }
        trickle.going.store(false, ordering: .relaxed)
        _ = stopped.wait(timeout: .now() + 5)
        #expect(released, "still served after \(trickle.received.withLock { $0.count }) bytes: \(counts())")
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var all = trickle.received.withLock { $0 }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var last = 0
        while true {
            last = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if last <= 0 { break }
            all += buffer.prefix(last)
        }
        #expect(last == 0, "the connection was not closed")
        #expect(String(decoding: all.prefix(512), as: UTF8.self).lowercased().hasPrefix("http/1.1 200"))
        #expect(all.count < LoopbackUpstream.bigBytes)
        #expect(Array(all.suffix(5)) != Array("0\r\n\r\n".utf8), "a cut-off answer ended like a complete one")
        #expect(upstream.hits("GET", "/v1/big") == 1)
    }

    /// An answer whose parts come 2.5 s apart, longer than the 1 s window,
    /// as SSE events may: waiting for the upstream is not waiting to write,
    /// so a client reading as it comes is never cut off.
    @Test(.timeLimit(.minutes(1)))
    func aStreamIdleLongerThanThePaceWindowIsNotCutOff() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port, clientSendTimeout: 1)
        defer { under.gateway.stop() }
        let size = 3 << 16
        let client = try connectGateway(under.port)
        defer { close(client) }
        #expect(GatewaySocket.writeAll(client, Array(under.request("/slow/\(size)/2500").utf8)))
        let answer = try ChunkedAnswer(reading: client)
        #expect(answer.head.hasPrefix("http/1.1 200"))
        #expect(answer.ended)
        #expect(answer.body == size)
        #expect(upstream.hits("GET", "/v1/slow/\(size)/2500") == 1)
    }

    /// An upstream faster than its reader, with an answer well past the
    /// 1 MiB mark: the whole answer arrives once, and the upstream saw the
    /// request once. corelibs-foundation restarts a task it suspends, so a
    /// pause sent the request, and its secret, again, and the client got
    /// the answer more than once.
    @Test(.timeLimit(.minutes(1)), arguments: ["GET", "POST"])
    func aRequestWhoseReaderFallsBehindReachesTheUpstreamOnce(method: String) throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        defer { under.gateway.stop() }
        let size = 6 << 20
        let client = try connectGateway(under.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        let body = method == "POST" ? #"{"input":"x"}"# : ""
        #expect(GatewaySocket.writeAll(client, Array(under.request("/bytes/\(size)", method: method, body: body).utf8)))
        let answer = try ChunkedAnswer(reading: client, pause: 1.5)
        #expect(answer.head.hasPrefix("http/1.1 200"))
        #expect(answer.closed, "the answer never ended")
        #expect(answer.ended)
        #expect(answer.body == size)
        #expect(answer.bodyIsAllX)
        #expect(upstream.hits(method, "/v1/bytes/\(size)") == 1)
        // The reader really fell behind: Darwin's callback waited for it,
        // and elsewhere more than 1 MiB waited for it.
        #if canImport(Darwin)
        #expect(under.transport.budget.paced > 0)
        #else
        #expect(under.transport.peakQueuedBytes > 1 << 20, "\(under.transport.peakQueuedBytes)")
        #endif
    }

    /// The upstream drops the connection without answering, on a fresh
    /// connection and on one an earlier request left open. Counted where
    /// the request arrives: libcurl sent it again on a reused connection,
    /// and a body request without its body, which then waited 300 s for
    /// the body. Darwin's URLSession sends a GET or HEAD up to three times
    /// on any dropped connection, with no setting to stop it; every other
    /// method once.
    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["GET", "HEAD", "OPTIONS", "DELETE", "POST", "PUT", "PATCH", "POST-empty"], [false, true])
    func aDroppedRequestIsNotSentAgain(method label: String, reused: Bool) throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let transport = URLSessionStreamingTransport()
        let method = label == "POST-empty" ? "POST" : label
        let body = ["POST", "PUT", "PATCH"].contains(label) ? Data(#"{"input":"x"}"#.utf8) : Data()
        if reused {
            let warm = CollectingSink()
            let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/ka/warm"))
            transport.send(SecretUpstreamRequest(method: "GET", url: url, headers: [], body: Data()), sink: warm)
            #expect(warm.result.ended == "finished")
        }
        let sink = CollectingSink()
        let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/drop/\(label)"))
        transport.send(SecretUpstreamRequest(method: method, url: url, headers: [], body: body), sink: sink)
        #expect(sink.result.ended?.hasPrefix("failed") == true, "\(sink.result.ended ?? "never ended")")
        let sent = upstream.hits(method, "/drop/\(label)")
        #if canImport(Darwin)
        if ["GET", "HEAD"].contains(method) {
            #expect((1...3).contains(sent), "sent \(sent) times")
            return
        }
        #endif
        #expect(sent == 1)
    }

    /// The upstream answers 401 with each kind of challenge. Counted where
    /// the request arrives, it arrives once, body and credential with it,
    /// and the transport hands on the 401. Darwin's URLSession answered a
    /// Basic challenge by sending the request again, for every method.
    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["basic", "digest", "bearer", "none"], ["GET", "POST", "PUT"])
    func aChallengedRequestIsNotSentAgain(challenge: String, method: String) throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let transport = URLSessionStreamingTransport()
        let body = method == "GET" ? Data() : Data(#"{"input":"x"}"#.utf8)
        let sink = CollectingSink()
        let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/auth/\(challenge)"))
        transport.send(
            SecretUpstreamRequest(
                method: method, url: url, headers: [("Authorization", "Bearer sk-live-REAL-0123456789")], body: body),
            sink: sink)
        #expect(sink.result.ended != nil)
        #expect(sink.headStatus == 401, "\(sink.result.ended ?? "never ended")")
        #expect(upstream.hits(method, "/auth/\(challenge)") == 1)
    }

    /// The server's certificate is still checked as URLSession checks it,
    /// and a request for a client certificate handled as before; every
    /// credential challenge is cancelled, never answered. corelibs-foundation
    /// raises neither of the first two, so on Linux even they are cancelled.
    @Test
    func onlyCredentialChallengesAreCancelled() {
        let decide = URLSessionStreamingDelegate.disposition(forAuthenticationMethod:)
        #if canImport(Darwin)
        #expect(decide(NSURLAuthenticationMethodServerTrust) == .performDefaultHandling)
        #expect(decide(NSURLAuthenticationMethodClientCertificate) == .performDefaultHandling)
        #else
        #expect(decide("NSURLAuthenticationMethodServerTrust") == .cancelAuthenticationChallenge)
        #expect(decide("NSURLAuthenticationMethodClientCertificate") == .cancelAuthenticationChallenge)
        #endif
        for method in [
            NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTMLForm,
            "an unknown method",
        ] {
            #expect(decide(method) == .cancelAuthenticationChallenge, "\(method)")
        }
    }

    /// Through the gateway, a challenged request reaches the upstream once,
    /// and its client gets the gateway's own refusal, never the challenge.
    @Test(.timeLimit(.minutes(1)), arguments: ["basic", "digest"])
    func aChallengedRequestIsRefusedToItsClientAfterOneSend(challenge: String) throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        defer { under.gateway.stop() }
        let answer = try gatewayExchange(
            port: under.port, under.request("/auth/\(challenge)", method: "POST", body: #"{"input":"x"}"#))
        #expect(answer.status == 502)
        #expect(answer.body.contains("the brokered credential was rejected upstream"), "\(answer.body)")
        #expect(upstream.hits("POST", "/v1/auth/\(challenge)") == 1)
    }

    /// An interim answer (`103 Early Hints`, or a `100 Continue` the gateway
    /// did not ask for) is not the answer: the final status and its whole
    /// body are handed on.
    @Test(.timeLimit(.minutes(1)), arguments: [103, 100])
    func anInterimAnswerIsPassedOverForTheFinalOne(code: Int) throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let sink = CollectingSink()
        let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/interim/\(code)"))
        URLSessionStreamingTransport().send(
            SecretUpstreamRequest(method: "GET", url: url, headers: [], body: Data()), sink: sink)
        #expect(sink.headStatus == 200)
        #expect(sink.result.body == "the final answer")
        #expect(sink.result.ended == "finished")
    }

    /// Through the gateway: the client gets the final answer whole, also
    /// when it asked for `100 Continue` (which the gateway sends itself).
    @Test(.timeLimit(.minutes(1)), arguments: [103, 100])
    func aClientGetsTheFinalAnswerPastAnUpstreamInterim(code: Int) throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        defer { under.gateway.stop() }
        let body = #"{"input":"x"}"#
        let expect = code == 100 ? "Expect: 100-continue\r\n" : ""
        let answer = try gatewayExchange(
            port: under.port,
            "POST /s/OPENAI_API_KEY/interim/\(code) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Authorization: Bearer \(under.placeholder.text)\r\n\(expect)"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(answer.status == 200, "\(answer.body)")
        #expect(answer.body == "the final answer")
        #expect(upstream.hits("POST", "/v1/interim/\(code)") == 1)
    }

    #if canImport(Darwin)
    /// Darwin's session stops reading while its callback waits, so a reader
    /// that pauses slows the upstream down instead of being cut off: an
    /// answer twice the old 8 MiB cut-off arrives whole and sent once, its
    /// callback waited for the reader, and about one of Darwin's bodies, up
    /// to 4 MiB, waits for it at most. 16 MiB, not 64: a debug build's
    /// scrubber moved 8 to 9 MB/s on a loaded host.
    @Test(.timeLimit(.minutes(1)))
    func aReaderThatPausesSlowsTheUpstreamInsteadOfBeingCutOff() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        defer { under.gateway.stop() }
        let size = 16 << 20
        let client = try connectGateway(under.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        #expect(GatewaySocket.writeAll(client, Array(under.request("/bytes/\(size)").utf8)))
        let answer = try ChunkedAnswer(reading: client, pause: 3)
        #expect(answer.head.hasPrefix("http/1.1 200"))
        #expect(answer.closed, "the answer never ended")
        #expect(answer.ended)
        #expect(answer.body == size)
        #expect(answer.bodyIsAllX)
        #expect(upstream.hits("GET", "/v1/bytes/\(size)") == 1)
        #expect(under.transport.budget.paced > 0)
        #expect(under.transport.peakQueuedBytes <= 8 << 20, "\(under.transport.peakQueuedBytes)")
    }
    #endif

    /// Without a hand-off, as on Linux, a reader that falls more than
    /// `perRequest` behind a fast upstream is cut off: no more than that
    /// ever waits for it, and what it reads is cut short, with no terminator.
    @Test(.timeLimit(.minutes(1)))
    func aReaderMoreThanTheCapBehindIsCutOff() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let limits = URLSessionStreamingTransport.Limits(perRequest: 4 << 20, total: .max, handoff: nil)
        let under = try GatewayUnderTest(upstreamPort: upstream.port, limits: limits)
        defer { under.gateway.stop() }
        let client = try connectGateway(under.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        #expect(GatewaySocket.writeAll(client, Array(under.request("/big").utf8)))
        let answer = try ChunkedAnswer(reading: client, pause: 3)
        #expect(answer.head.hasPrefix("http/1.1 200"))
        #expect(answer.closed, "the connection was not closed")
        #expect(answer.ended == false, "a cut-off answer ended like a complete one")
        #expect(answer.body < LoopbackUpstream.bigBytes)
        #expect(upstream.hits("GET", "/v1/big") == 1)
        #expect(under.transport.peakQueuedBytes <= limits.perRequest)
    }

    /// Without a hand-off, a reader that keeps up with an upstream sending
    /// about 8 MiB a second gets all of an answer three times `perRequest`,
    /// sent once. It starts 0.3 s late and pauses after each read, so more
    /// than 512 KiB waits for it before it catches up.
    @Test(.timeLimit(.minutes(1)))
    func aLiveReaderGetsTheWholeOfAnAnswerLargerThanTheCap() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let limits = URLSessionStreamingTransport.Limits(perRequest: 4 << 20, total: .max, handoff: nil)
        let under = try GatewayUnderTest(upstreamPort: upstream.port, limits: limits)
        defer { under.gateway.stop() }
        let size = 12 << 20
        let client = try connectGateway(under.port)
        defer { close(client) }
        #expect(GatewaySocket.writeAll(client, Array(under.request("/slow/\(size)/8").utf8)))
        let answer = try ChunkedAnswer(reading: client, pause: 0.3, perRead: 0.001)
        #expect(answer.closed, "the answer never ended")
        #expect(answer.ended)
        #expect(answer.body == size)
        #expect(answer.bodyIsAllX)
        #expect(upstream.hits("GET", "/v1/slow/\(size)/8") == 1)
        #expect(under.transport.peakQueuedBytes > 512 << 10, "\(under.transport.peakQueuedBytes)")
    }

    /// The total counts only what each request holds beyond its exempt
    /// first bytes, so a request keeping up is never failed for the others.
    /// When it is full, the request holding the most is named to fail, once.
    @Test
    func theBudgetNamesTheLargestHolderWhenTheTotalIsFull() {
        let budget = URLSessionStreamingBudget(.init(perRequest: 8, total: 4, exempt: 2))
        let (a, b, c) = (idleExchange(budget), idleExchange(budget), idleExchange(budget))
        #expect(budget.admit(2, for: a).taken)
        #expect(budget.admit(2, for: b).taken)
        #expect(budget.admit(4, for: a).taken)
        #expect(budget.admit(1, for: b).victim === a, "the total is full and a holds the most")
        #expect(budget.admit(1, for: b).refused, "a is named once; nobody else holds more than b")
        budget.release(6, for: a)
        #expect(budget.admit(1, for: b).taken)
        #expect(budget.admit(2, for: c).taken, "within its exempt bytes")
        #expect(budget.admit(9, for: c).refused, "past the per-request cap")
        #expect(budget.waiting == 5)
        #expect(budget.peak == 8)
    }

    /// The asker holding the most of a full total is refused itself; a
    /// smaller holder is never failed for it, and a smaller asker names it.
    @Test
    func theLargestHolderAskingForMoreIsRefusedItself() {
        let budget = URLSessionStreamingBudget(.init(perRequest: 100, total: 4, exempt: 0))
        let (a, b) = (idleExchange(budget), idleExchange(budget))
        #expect(budget.admit(3, for: a).taken)
        #expect(budget.admit(1, for: b).taken)
        #expect(budget.admit(1, for: a).refused)
        #expect(budget.admit(1, for: b).victim === a, "a holds more than b")
    }

    /// The total full, the request holding the most fails, though its
    /// upstream had already finished; the smaller one asking for room then
    /// arrives whole, and every byte is given back.
    @Test(.timeLimit(.minutes(1)))
    func aFullTotalFailsTheRequestHoldingTheMost() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        // The large answer alone fits the total; Darwin's bodies of up to
        // 4 MiB never bring the small one past what the large one holds.
        let limits = URLSessionStreamingTransport.Limits(
            perRequest: 64 << 20, total: 12 << 20, exempt: 1 << 20, handoff: nil)
        let transport = URLSessionStreamingTransport(limits: limits)
        let (large, small) = ((12 << 20) + 1, 6 << 20)
        let (largeGate, smallGate) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        let (largeSink, smallSink) = (GatedSink(largeGate), GatedSink(smallGate))
        let done = DispatchGroup()
        for (size, sink) in [(large, largeSink), (small, smallSink)] {
            let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/bytes/\(size)"))
            done.enter()
            Thread.detachNewThread {
                transport.send(SecretUpstreamRequest(method: "GET", url: url, headers: [], body: Data()), sink: sink)
                done.leave()
            }
            // The large answer is all queued before the small one starts.
            if size == large { #expect(eventually { transport.budget.waiting == large }) }
        }
        // Only failing gives back what the large one queued: its sink has
        // not returned. What stays counted is the body that sink holds.
        #expect(eventually { transport.budget.waiting < large }, "the large request was not failed")
        smallGate.signal()
        #expect(eventually { smallSink.result.ended != nil })
        largeGate.signal()
        #expect(done.wait(timeout: .now() + 20) == .success, "some sends never returned")
        #expect(smallSink.result.ended == "finished")
        #expect(smallSink.result.bytes == small)
        #expect(largeSink.result.ended?.hasPrefix("failed: the client fell too far behind") == true)
        #expect(largeSink.result.bytes < large)
        #expect(transport.budget.waiting == 0)
        #expect(upstream.hits("GET", "/bytes/\(large)") == 1)
        #expect(upstream.hits("GET", "/bytes/\(small)") == 1)
    }

    /// A request whose sink does not return holds up only itself: another
    /// large answer through the same transport arrives whole meanwhile, and
    /// the stalled one is still whole once its sink returns.
    @Test(.timeLimit(.minutes(1)))
    func aStalledSinkDoesNotHoldUpAnotherRequest() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let transport = URLSessionStreamingTransport()
        let size = 32 << 20
        let gate = DispatchSemaphore(value: 0)
        let stalled = GatedSink(gate)
        let done = DispatchGroup()
        let stalledURL = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/bytes/\(size)"))
        done.enter()
        Thread.detachNewThread {
            transport.send(
                SecretUpstreamRequest(method: "GET", url: stalledURL, headers: [], body: Data()), sink: stalled)
            done.leave()
        }
        #expect(eventually { stalled.result.bytes > 0 })
        // Created at 0 and opened: libdispatch traps when a semaphore is
        // freed below the value it was created with.
        let open = DispatchSemaphore(value: 0)
        open.signal()
        let live = GatedSink(open)
        let liveURL = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/bytes/\(size + 1)"))
        transport.send(SecretUpstreamRequest(method: "GET", url: liveURL, headers: [], body: Data()), sink: live)
        #expect(live.result.ended == "finished")
        #expect(live.result.bytes == size + 1)
        #expect(stalled.result.ended == nil, "the stalled request ended before its sink returned")
        gate.signal()
        #expect(done.wait(timeout: .now() + 20) == .success)
        #expect(stalled.result.ended == "finished")
        #expect(stalled.result.bytes == size)
    }

    /// Darwin keeps a session that served its request cleanly, so requests
    /// one after another share one session and one connection. Linux makes
    /// a session, and a connection, for each, and invalidates each after.
    @Test(.timeLimit(.minutes(1)))
    func sequentialRequestsReuseASessionOnlyOnDarwin() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let transport = URLSessionStreamingTransport()
        let count = 4
        for index in 0..<count {
            let sink = CollectingSink()
            let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/ka/r\(index)"))
            transport.send(SecretUpstreamRequest(method: "GET", url: url, headers: [], body: Data()), sink: sink)
            #expect(sink.result.ended == "finished")
            #expect(sink.result.body == "ok:/ka/r\(index)")
        }
        #if canImport(Darwin)
        #expect(transport.sessionCounts.made == 1)
        #expect(upstream.connections == 1)
        #else
        #expect(transport.sessionCounts.made == count)
        #expect(upstream.connections == count)
        #expect(eventually { transport.sessionCounts.live == 0 }, "\(transport.sessionCounts)")
        #endif
    }

    /// Readers stalled together never hold more than the total beyond each
    /// one's exempt bytes, the requests that would pass it fail, the others
    /// arrive whole, and every byte is given back once all have returned.
    @Test(.timeLimit(.minutes(1)))
    func stalledReadersTogetherStayWithinTheTotal() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let limits = URLSessionStreamingTransport.Limits(
            perRequest: 8 << 20, total: 4 << 20, exempt: 1 << 20, handoff: nil)
        let transport = URLSessionStreamingTransport(limits: limits)
        let count = 4
        let size = 6 << 20
        let gate = DispatchSemaphore(value: 0)
        let sinks = (0..<count).map { _ in GatedSink(gate) }
        let done = DispatchGroup()
        for (index, sink) in sinks.enumerated() {
            let url = try #require(URL(string: "http://127.0.0.1:\(upstream.port)/bytes/\(size + index)"))
            done.enter()
            Thread.detachNewThread {
                transport.send(SecretUpstreamRequest(method: "GET", url: url, headers: [], body: Data()), sink: sink)
                done.leave()
            }
        }
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<count { gate.signal() }
        #expect(done.wait(timeout: .now() + 20) == .success, "some sends never returned")
        #expect(transport.peakQueuedBytes <= limits.total + count * limits.exempt)
        #expect(transport.budget.waiting == 0)
        let ends = sinks.map(\.result)
        #expect(ends.contains { $0.ended?.hasPrefix("failed: the client fell too far behind") == true })
        for (index, end) in ends.enumerated() {
            #expect(end.ended != nil)
            if end.ended == "finished" { #expect(end.bytes == size + index) }
            #expect(upstream.hits("GET", "/bytes/\(size + index)") == 1)
        }
    }

    /// Clients that send their request heads a byte at a time hold their
    /// slots only until the head deadline. With every slot held that way, a
    /// further request is turned away busy, then answered once the deadline
    /// has freed the slots, while they are still trickling; each of them is
    /// answered 408.
    @Test(.timeLimit(.minutes(1)))
    func clientsThatTrickleTheirHeadsAreDroppedAtTheDeadline() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port, headDeadline: 1)
        defer { under.gateway.stop() }
        let tricklers = try (0..<SecretGateway.maximumConnections).map { _ in try connectGateway(under.port) }
        defer { tricklers.forEach { close($0) } }
        let head = Array(under.request("/trickle").utf8)
        let trickled = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            // 8 s of trickling, far past the 1 s deadline; a connection the
            // gateway has answered gets nothing more.
            for index in 0..<40 {
                for fd in tricklers where readable(fd) == false { _ = GatewaySocket.writeAll(fd, [head[index]]) }
                Thread.sleep(forTimeInterval: 0.2)
            }
            trickled.signal()
        }
        let until = Date().addingTimeInterval(6)
        var answer = try gatewayExchange(port: under.port, under.request("/after"))
        while answer.status == 503, Date() < until {
            Thread.sleep(forTimeInterval: 0.1)
            answer = try gatewayExchange(port: under.port, under.request("/after"))
        }
        #expect(answer.status == 200)
        #expect(answer.body == "ok:/v1/after")
        #expect(trickled.wait(timeout: .now()) == .timedOut, "answered only once the trickling had stopped")
        let answers = tricklers.map(plainAnswer)
        let timedOut = answers.filter { $0.hasPrefix("HTTP/1.1 408") && $0.contains("the request did not arrive in time") }
        #expect(timedOut.count == tricklers.count, "\(answers.filter { $0.hasPrefix("HTTP/1.1 408") == false }.prefix(3))")
        _ = trickled.wait(timeout: .now() + 10)
        #expect(upstream.hits("GET", "/v1/trickle") == 0)
    }

    /// A client that trickles its request body is answered 408 at the body
    /// deadline, while it is still sending, and nothing is forwarded.
    @Test(.timeLimit(.minutes(1)))
    func aClientThatTricklesItsBodyIsDroppedAtTheDeadline() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port, bodyDeadline: 1)
        defer { under.gateway.stop() }
        let client = try connectGateway(under.port)
        defer { close(client) }
        let full = under.request("/upload", method: "POST", body: String(repeating: "y", count: 64))
        let bytes = Array(full.utf8)
        let headLength = bytes.count - 64
        #expect(GatewaySocket.writeAll(client, Array(bytes[..<headLength])))
        let trickled = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            // 12 s of trickling, and never the whole body.
            for index in headLength..<(headLength + 60) {
                guard readable(client) == false else { break }
                _ = GatewaySocket.writeAll(client, [bytes[index]])
                Thread.sleep(forTimeInterval: 0.2)
            }
            trickled.signal()
        }
        var state = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        let ready = poll(&state, 1, 10_000)
        let stillSending = trickled.wait(timeout: .now()) == .timedOut
        #expect(ready == 1, "the trickling client was still held after 10 s")
        #expect(stillSending, "answered only once the trickling had stopped")
        let answer = plainAnswer(client)
        #expect(answer.hasPrefix("HTTP/1.1 408"), "\(answer.prefix(80))")
        #expect(answer.contains("the request did not arrive in time"))
        _ = trickled.wait(timeout: .now() + 15)
        #expect(upstream.hits("POST", "/v1/upload") == 0)
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
