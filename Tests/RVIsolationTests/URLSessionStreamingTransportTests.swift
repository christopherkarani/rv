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

/// Loopback HTTP/1.1 upstream, one thread per connection, counting the
/// requests it receives by method and path. `/big` answers `bigBytes` x's
/// with a Content-Length, `/bytes/N` answers N x's, and `/slow/N/ms`
/// answers N x's in 64 KiB blocks `ms` milliseconds apart; any other path
/// answers `ok:<path>`. A request body is read before the answer.
private final class LoopbackUpstream: @unchecked Sendable {
    static let bigBytes = 64 << 20
    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var hits: [String: Int] = [:]

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
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let separator = Array("\r\n\r\n".utf8)
        var request: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var headEnd: Int?
        while headEnd == nil {
            guard request.count < 65_536 else { return }
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            request += buffer.prefix(n)
            if request.count >= separator.count {
                headEnd = (0...(request.count - separator.count)).first {
                    Array(request[$0..<($0 + separator.count)]) == separator
                }
            }
        }
        let end = headEnd ?? 0
        let lines = String(decoding: request[..<end], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ").map(String.init)
        let method = parts.first ?? "?"
        let path = parts.dropFirst().first ?? "/"
        let length = lines.dropFirst().compactMap { line -> Int? in
            let field = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return field.count == 2 && field[0].lowercased() == "content-length" ? Int(field[1]) : nil
        }.first ?? 0
        var bodyRead = request.count - end - separator.count
        while bodyRead < length {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            bodyRead += n
        }
        lock.lock()
        hits["\(method) \(path)", default: 0] += 1
        lock.unlock()
        let segments = path.split(separator: "/").map(String.init)
        if path.hasSuffix("/big") {
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
        upstreamPort: Int, clientSendTimeout: Int? = nil, headDeadline: TimeInterval? = nil,
        bodyDeadline: TimeInterval? = nil
    ) throws {
        transport = URLSessionStreamingTransport()
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

    /// An upstream faster than its reader, with an answer well past the
    /// 1 MiB mark and under the 8 MiB cap: the whole answer arrives once,
    /// and the upstream saw the request once. corelibs-foundation restarts
    /// a task it suspends, so a pause sent the request, and its secret,
    /// again, and the client got the answer more than once.
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
        // The reader really fell behind: more than the 1 MiB at which the
        // transport used to pause waited at once.
        #expect(under.transport.peakQueuedBytes > 1 << 20)
    }

    /// A reader that falls more than 8 MiB behind a fast upstream is cut
    /// off: no more than 8 MiB ever waits for it, and what it reads is cut
    /// short, with no terminator.
    @Test(.timeLimit(.minutes(1)))
    func aReaderMoreThanTheCapBehindIsCutOff() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
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
        #expect(under.transport.peakQueuedBytes <= 8 << 20)
    }

    /// A live reader of an answer three times the cap, from an upstream
    /// that sends about 8 MiB a second, gets all of it, and the upstream
    /// saw the request once. The reader starts late, so more than the mark
    /// waits for it before it catches up.
    @Test(.timeLimit(.minutes(1)))
    func aSlowLiveReaderGetsTheWholeOfALargeAnswer() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let under = try GatewayUnderTest(upstreamPort: upstream.port)
        defer { under.gateway.stop() }
        let size = 24 << 20
        let client = try connectGateway(under.port)
        defer { close(client) }
        #expect(GatewaySocket.writeAll(client, Array(under.request("/slow/\(size)/8").utf8)))
        let answer = try ChunkedAnswer(reading: client, pause: 0.5, perRead: 0.001)
        #expect(answer.closed, "the answer never ended")
        #expect(answer.ended)
        #expect(answer.body == size)
        #expect(answer.bodyIsAllX)
        #expect(upstream.hits("GET", "/v1/slow/\(size)/8") == 1)
        #expect(under.transport.peakQueuedBytes <= 8 << 20)
    }

    /// The total counts only what each request holds beyond its exempt
    /// first bytes, so a request keeping up is never failed for the others.
    @Test
    func theBudgetCountsOnlyWhatEachRequestHoldsPastItsExemptBytes() {
        let budget = URLSessionStreamingBudget(.init(perRequest: 8, total: 4, exempt: 2))
        #expect(budget.admit(2, holding: 0))
        #expect(budget.admit(2, holding: 0))
        #expect(budget.admit(4, holding: 2))
        #expect(budget.admit(1, holding: 6) == false, "past the total")
        #expect(budget.admit(1, holding: 0), "within its exempt bytes")
        #expect(budget.admit(9, holding: 0) == false, "past the per-request cap")
        budget.release(4, holding: 6)
        #expect(budget.admit(4, holding: 2))
        #expect(budget.waiting == 9)
        #expect(budget.peak == 9)
    }

    /// Readers stalled together never hold more than the total beyond each
    /// one's exempt bytes, the requests that would pass it fail, the others
    /// arrive whole, and every byte is given back once all have returned.
    @Test(.timeLimit(.minutes(1)))
    func stalledReadersTogetherStayWithinTheTotal() throws {
        let upstream = try LoopbackUpstream()
        defer { upstream.stop() }
        let limits = URLSessionStreamingTransport.Limits(perRequest: 8 << 20, total: 4 << 20, exempt: 1 << 20)
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
    /// slots only until the head deadline. With every slot held that way,
    /// a request made after the deadline is answered, and each trickling
    /// connection has been answered or closed.
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
            for index in 0..<15 {
                for fd in tricklers { _ = GatewaySocket.writeAll(fd, [head[index]]) }
                Thread.sleep(forTimeInterval: 0.2)
            }
            trickled.signal()
        }
        Thread.sleep(forTimeInterval: 1.6)
        let answer = try gatewayExchange(port: under.port, under.request("/after"))
        #expect(answer.status == 200)
        #expect(answer.body == "ok:/v1/after")
        _ = trickled.wait(timeout: .now() + 10)
        let held = tricklers.filter { fd in
            var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            return poll(&state, 1, 0) == 0
        }
        #expect(held.isEmpty, "\(held.count) trickling connections still held")
        #expect(upstream.hits("GET", "/v1/trickle") == 0)
    }

    /// A client that trickles its request body is dropped at the body
    /// deadline, not held while it keeps sending.
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
        let started = Date()
        let trickled = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            for index in headLength..<(headLength + 25) {
                _ = GatewaySocket.writeAll(client, [bytes[index]])
                Thread.sleep(forTimeInterval: 0.2)
            }
            trickled.signal()
        }
        var state = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        let ready = poll(&state, 1, 4_000)
        let waited = Date().timeIntervalSince(started)
        _ = trickled.wait(timeout: .now() + 10)
        #expect(ready == 1, "the trickling client was still held after 4 s")
        #expect(waited < 3)
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
