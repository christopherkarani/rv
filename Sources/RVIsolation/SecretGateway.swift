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

/// What one gateway request did. Carries names and a fingerprint, never values.
public struct SecretUseRecord: Sendable, Equatable {
    public var secret: String?
    public var runtime: String?
    public var upstreamHost: String?
    public var method: String
    /// Path only; the query string is never recorded.
    public var path: String
    public var status: Int
    public var allowed: Bool
    public var reason: String?
    public var fingerprint: String?
    public var responseBytes: Int
}

public struct SecretUpstreamRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [(name: String, value: String)]
    public var body: Data
}

/// Receives one upstream response. `body` returns false once the client is gone.
public protocol SecretResponseSink: AnyObject, Sendable {
    func head(status: Int, headers: [(name: String, value: String)])
    func body(_ data: Data) -> Bool
    func finish()
    func fail(_ reason: String)
}

/// Performs one upstream exchange and blocks until the sink is finished or failed.
public struct SecretUpstreamTransport: Sendable {
    public var send: @Sendable (SecretUpstreamRequest, SecretResponseSink) -> Void

    public init(send: @escaping @Sendable (SecretUpstreamRequest, SecretResponseSink) -> Void) {
        self.send = send
    }

    public static var urlSession: SecretUpstreamTransport {
        let transport = URLSessionStreamingTransport()
        return SecretUpstreamTransport { request, sink in transport.send(request, sink: sink) }
    }
}

/// Loopback reverse proxy that swaps per-launch placeholders for real
/// secret values, only toward the secret's bound upstream origin.
public final class SecretGateway: @unchecked Sendable {
    public struct Entry: Sendable {
        public var secret: String
        public var prefix: String
        public var value: SecretValue
        public var upstream: URL
        public var fingerprint: String?
        public var runtime: String?
    }

    public static let maximumBodyBytes = 32 * 1024 * 1024
    static let maximumConnections = 64

    private let transport: SecretUpstreamTransport
    private let audit: @Sendable (SecretUseRecord) -> Void
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var listenFD: Int32 = -1
    private var boundPort: Int?
    private let slots = DispatchSemaphore(value: SecretGateway.maximumConnections)
    private let acceptQueue = DispatchQueue(label: "rv.secret-gateway.accept", qos: .userInitiated)

    public init(
        transport: SecretUpstreamTransport = .urlSession,
        audit: @escaping @Sendable (SecretUseRecord) -> Void
    ) {
        self.transport = transport
        self.audit = audit
    }

    deinit {
        stop()
    }

    public var port: Int? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public func baseURL(secret: String) -> String? {
        port.map { "http://127.0.0.1:\($0)/s/\(secret)" }
    }

    public func register(_ placeholder: SecretPlaceholder, entry: Entry) {
        lock.lock()
        entries[placeholder.token] = entry
        lock.unlock()
    }

    public func bind(_ placeholders: [SecretPlaceholder], runtime: String) {
        lock.lock()
        for placeholder in placeholders { entries[placeholder.token]?.runtime = runtime }
        lock.unlock()
    }

    public func revoke(_ placeholders: [SecretPlaceholder]) {
        lock.lock()
        for placeholder in placeholders { entries[placeholder.token] = nil }
        lock.unlock()
    }

    var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func entry(_ token: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]
    }

    public func start() -> Result<Int, EgressStartError> {
        lock.lock()
        if let boundPort {
            lock.unlock()
            return .success(boundPort)
        }
        lock.unlock()
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return .failure(.socketFailed(errno: errno)) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                #if canImport(Darwin)
                Darwin.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            return .failure(.bindFailed(errno: code))
        }
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            return .failure(.listenFailed(errno: code))
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            close(fd)
            return .failure(.addressFailed(errno: code))
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        lock.lock()
        listenFD = fd
        boundPort = port
        lock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
        return .success(port)
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        boundPort = nil
        entries.removeAll()
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard slots.wait(timeout: .now()) == .success else {
                GatewaySocket.writeAll(client, GatewaySocket.plainResponse(status: 503, reason: "gateway busy"))
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { close(client) }
                guard let self else { return }
                defer { self.slots.signal() }
                self.handle(client)
            }
        }
    }

    func handle(_ client: Int32) {
        let reader = GatewaySocket.Reader(fd: client)
        guard let headBytes = reader.readHead(limit: GatewayRequestHead.maximumBytes),
            let head = GatewayRequestHead.parse(headBytes)
        else {
            refuse(client, .malformed, method: "?", path: "?", secret: nil)
            return
        }
        let path = String(head.target.prefix { $0 != "?" })
        guard let route = GatewayRoute(target: head.target) else {
            refuse(client, .unknownRoute, method: head.method, path: path, secret: nil)
            return
        }
        let substituted = GatewaySubstitution.apply(head, route: route) { token in
            entry(token).map {
                GatewaySubstitution.Live(token: token, secret: $0.secret, prefix: $0.prefix, value: $0.value)
            }
        }
        let rewritten: GatewayRequestHead
        let token: String
        switch substituted {
        case .failure(let refusal):
            refuse(client, refusal, method: head.method, path: path, secret: route.secret)
            return
        case .success(let result):
            rewritten = result.head
            token = result.used.token
        }
        guard let live = entry(token),
            let upstreamRoute = GatewayRoute(target: rewritten.target),
            let url = upstreamRoute.upstreamURL(base: live.upstream)
        else {
            refuse(client, .unknownPlaceholder, method: head.method, path: path, secret: route.secret)
            return
        }
        if head.header("Expect")?.lowercased() == "100-continue" {
            GatewaySocket.writeAll(client, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        guard let body = readBody(reader, head: head) else {
            refuse(client, .tooLarge, method: head.method, path: path, secret: route.secret)
            return
        }
        let headers = rewritten.headers.filter {
            GatewayHeaders.dropOnRequest.contains($0.name.lowercased()) == false
        }
        let sink = GatewayResponseWriter(
            fd: client,
            method: head.method,
            scrub: [(live.value.bytes, Array(SecretPlaceholder(token: token, prefix: live.prefix).text.utf8))]
        )
        transport.send(SecretUpstreamRequest(method: head.method, url: url, headers: headers, body: body), sink)
        audit(SecretUseRecord(
            secret: live.secret,
            runtime: live.runtime,
            upstreamHost: url.host,
            method: head.method,
            path: path,
            status: sink.status,
            allowed: true,
            reason: sink.failure,
            fingerprint: live.fingerprint,
            responseBytes: sink.bytesWritten
        ))
    }

    private func readBody(_ reader: GatewaySocket.Reader, head: GatewayRequestHead) -> Data? {
        if let encoding = head.header("Transfer-Encoding") {
            guard encoding.lowercased() == "chunked" else { return nil }
            return reader.readChunked(limit: Self.maximumBodyBytes)
        }
        guard let lengthText = head.header("Content-Length") else { return Data() }
        guard let length = Int(lengthText), length >= 0, length <= Self.maximumBodyBytes else { return nil }
        return reader.readExactly(length)
    }

    private func refuse(_ client: Int32, _ refusal: GatewayRefusal, method: String, path: String, secret: String?) {
        GatewaySocket.writeAll(client, GatewaySocket.plainResponse(status: refusal.status, reason: refusal.reason))
        audit(SecretUseRecord(
            secret: secret, runtime: nil, upstreamHost: nil, method: method, path: path,
            status: refusal.status, allowed: false, reason: refusal.reason, fingerprint: nil, responseBytes: 0
        ))
    }
}

/// Writes one upstream response to the agent: chunked framing, real values
/// replaced by the placeholder in headers and body.
final class GatewayResponseWriter: SecretResponseSink, @unchecked Sendable {
    private let fd: Int32
    private let method: String
    private let pairs: [(needle: [UInt8], replacement: [UInt8])]
    private let lock = NSLock()
    private var scrubber: SecretScrubber
    private var wroteHead = false
    private var framed = true
    private var closed = false
    private(set) var status = 502
    private(set) var bytesWritten = 0
    private(set) var failure: String?

    init(fd: Int32, method: String, scrub pairs: [(needle: [UInt8], replacement: [UInt8])]) {
        self.fd = fd
        self.method = method
        self.pairs = pairs
        scrubber = SecretScrubber(pairs)
    }

    func head(status: Int, headers: [(name: String, value: String)]) {
        lock.lock()
        defer { lock.unlock() }
        guard wroteHead == false else { return }
        wroteHead = true
        self.status = status
        framed = method != "HEAD" && status != 204 && status != 304 && (status < 100 || status >= 200)
        var text = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for header in headers where GatewayHeaders.dropOnResponse.contains(header.name.lowercased()) == false {
            let value = SecretScrubber.scrub(header.value, pairs)
            guard value.contains("\r") == false, value.contains("\n") == false else { continue }
            text += "\(header.name): \(value)\r\n"
        }
        if framed { text += "Transfer-Encoding: chunked\r\n" }
        text += "Connection: close\r\n\r\n"
        closed = GatewaySocket.writeAll(fd, Array(text.utf8)) == false
    }

    func body(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard closed == false, framed else { return closed == false }
        let clean = scrubber.process(Array(data))
        return writeChunk(clean)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard closed == false else { return }
        if wroteHead == false {
            closed = true
            failure = "upstream sent no response"
            GatewaySocket.writeAll(fd, GatewaySocket.plainResponse(status: 502, reason: "upstream sent no response"))
            return
        }
        if framed {
            _ = writeChunk(scrubber.finish())
            _ = GatewaySocket.writeAll(fd, Array("0\r\n\r\n".utf8))
        }
        closed = true
    }

    func fail(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        failure = reason
        guard closed == false else { return }
        closed = true
        if wroteHead == false {
            status = 502
            GatewaySocket.writeAll(fd, GatewaySocket.plainResponse(status: 502, reason: "upstream failed: \(reason)"))
        }
    }

    private func writeChunk(_ bytes: [UInt8]) -> Bool {
        guard bytes.isEmpty == false else { return true }
        bytesWritten += bytes.count
        let frame = Array(String(bytes.count, radix: 16).utf8) + [13, 10] + bytes + [13, 10]
        if GatewaySocket.writeAll(fd, frame) == false { closed = true }
        return closed == false
    }
}

enum GatewaySocket {
    #if canImport(Darwin)
    static let sendFlags: Int32 = 0
    #else
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    @discardableResult
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base + written, raw.count - written, sendFlags)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }

    static func plainResponse(status: Int, reason: String) -> [UInt8] {
        let body = "rv secret gateway: \(reason)\n"
        let phrase = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        return Array(
            ("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    final class Reader {
        private let fd: Int32
        private var buffer: [UInt8] = []

        init(fd: Int32) {
            self.fd = fd
        }

        private func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                buffer += chunk.prefix(n)
                return true
            }
        }

        func readHead(limit: Int) -> [UInt8]? {
            let terminator: [UInt8] = [13, 10, 13, 10]
            var searchFrom = 0
            while true {
                if buffer.count >= 4 {
                    var index = max(0, searchFrom - 3)
                    while index <= buffer.count - 4 {
                        if buffer[index] == 13, Array(buffer[index..<index + 4]) == terminator {
                            let head = Array(buffer[..<index])
                            buffer.removeFirst(index + 4)
                            return head
                        }
                        index += 1
                    }
                    searchFrom = buffer.count
                }
                guard buffer.count <= limit, fill() else { return nil }
            }
        }

        func readExactly(_ count: Int) -> Data? {
            while buffer.count < count {
                guard fill() else { return nil }
            }
            let data = Data(buffer[..<count])
            buffer.removeFirst(count)
            return data
        }

        func readLine(limit: Int = 4_096) -> String? {
            while true {
                if let index = buffer.firstIndex(of: 10), index > 0, buffer[index - 1] == 13 {
                    let line = String(decoding: buffer[..<(index - 1)], as: UTF8.self)
                    buffer.removeFirst(index + 1)
                    return line
                }
                guard buffer.count <= limit, fill() else { return nil }
            }
        }

        func readChunked(limit: Int) -> Data? {
            var body = Data()
            while true {
                guard let line = readLine() else { return nil }
                let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    return nil
                }
                if size == 0 {
                    while let trailer = readLine() {
                        if trailer.isEmpty { return body }
                    }
                    return nil
                }
                guard body.count + size <= limit, let chunk = readExactly(size), readExactly(2) == Data([13, 10])
                else { return nil }
                body.append(chunk)
            }
        }
    }
}

/// URLSession upstream with streaming delivery, no cookies, cache, or redirects.
final class URLSessionStreamingTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: (sink: SecretResponseSink, done: DispatchSemaphore)] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    func send(_ request: SecretUpstreamRequest, sink: SecretResponseSink) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for header in request.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if request.body.isEmpty == false || ["POST", "PUT", "PATCH"].contains(request.method) {
            urlRequest.httpBody = request.body
        }
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: urlRequest)
        lock.lock()
        sinks[task.taskIdentifier] = (sink, done)
        lock.unlock()
        task.resume()
        done.wait()
    }

    private func sink(for task: URLSessionTask) -> SecretResponseSink? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[task.taskIdentifier]?.sink
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let sink = sink(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let headers = http.allHeaderFields.compactMap { key, value -> (name: String, value: String)? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return (name, text)
        }
        sink.head(status: http.statusCode, headers: headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let sink = sink(for: dataTask) else { return }
        if sink.body(data) == false { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = sinks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if let error {
            entry.sink.fail(error.localizedDescription)
        } else {
            entry.sink.finish()
        }
        entry.done.signal()
    }
}
