#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import Synchronization

/// One denied CONNECT, recorded for the allowlist learning loop.
public struct EgressProxyDenial: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var reason: String
    public var recordedAt: Date

    public init(host: String, port: Int, reason: String, recordedAt: Date) {
        self.host = host
        self.port = port
        self.reason = reason
        self.recordedAt = recordedAt
    }
}

/// HTTP CONNECT proxy for contained agent runtimes.
///
/// Binds 127.0.0.1 on an ephemeral port; the cage reaches it through the
/// seatbelt `localhost` rule and can dial nothing else directly. Each
/// CONNECT is admitted by `EgressHostPolicy` (exact HTTPS hosts, or
/// loopback targets on any port) and resolved here, host-side: clients
/// never supply IPs. Denials are logged; allowed streams relay as opaque
/// bytes. One proxy per workspace host; `stop` ends new accepts and lets
/// in-flight relays drain.
public final class EgressProxy: @unchecked Sendable {
    private let policy: EgressHostPolicy
    private let record: @Sendable (EgressProxyDenial) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "rv.egress.accept")
    private let relayQueue = DispatchQueue(label: "rv.egress.relay", attributes: .concurrent)

    public init(
        policy: EgressHostPolicy = .agentAPIs,
        record: (@Sendable (EgressProxyDenial) -> Void)? = nil
    ) {
        self.policy = policy
        self.record = record ?? EgressProxy.productionDenialLog()
    }

    /// Bound port after `start` returns non-nil.
    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    private var boundPort: Int = 0

    /// Bind 127.0.0.1:0, listen, and serve until `stop`. Returns the bound
    /// port, or nil when the socket cannot be established (fail closed:
    /// without a proxy the cage has no route out at all).
    public func start() -> Int? {
        lock.lock()
        if running {
            let port = boundPort
            lock.unlock()
            return port
        }
        lock.unlock()
        var hints = addrinfo()
        memset(&hints, 0, MemoryLayout<addrinfo>.size)
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", "0", &hints, &info) == 0, let first = info else {
            return nil
        }
        defer { freeaddrinfo(first) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0,
            listen(fd, 16) == 0
        else {
            close(fd)
            return nil
        }
        var name = sockaddr_storage()
        var nameLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let bound: Int = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                guard getsockname(fd, address, &nameLength) == 0 else { return 0 }
                return Int(EgressProxy.port(of: address))
            }
        }
        guard bound > 0 else {
            close(fd)
            return nil
        }
        lock.lock()
        listenFD = fd
        boundPort = bound
        running = true
        lock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return bound
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        boundPort = 0
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    deinit {
        stop()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning() {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let fd: Int32 = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    lock.lock()
                    let listen = listenFD
                    lock.unlock()
                    guard listen >= 0 else { return Int32(-1) }
                    return accept(listen, address, &peerLength)
                }
            }
            guard fd >= 0 else {
                if isRunning() { usleep(50_000) }
                continue
            }
            relayQueue.async { [weak self] in self?.serve(client: fd) }
        }
    }

    private func serve(client: Int32) {
        EgressProxy.suppressSIGPIPE(client)
        EgressProxy.setTimeout(client, seconds: 10)
        switch EgressProxy.readHeaders(client, maximumBytes: 65_536) {
        case .failure:
            close(client)
            return
        case .oversized:
            deny(client: client, host: "", port: 0, reason: "header-too-large")
            return
        case .success(let header, let leftover):
            serveRequest(client: client, header: header, leftover: leftover)
        }
    }

    private func serveRequest(client: Int32, header: String, leftover: [UInt8]) {
        if let target = EgressProxy.parseCONNECT(header: header) {
            let external = policy.allows(host: target.host, port: target.port)
            let loopback = policy.allowsLoopbackTarget(host: target.host, port: target.port)
            guard external || loopback else {
                deny(client: client, host: target.host, port: target.port, reason: "denied-policy")
                return
            }
            guard let upstream = EgressProxy.dial(host: target.host, port: target.port) else {
                deny(client: client, host: target.host, port: target.port, reason: "dial-failed")
                return
            }
            EgressProxy.suppressSIGPIPE(upstream)
            guard EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)),
                leftover.isEmpty || EgressProxy.writeAll(upstream, bytes: leftover)
            else {
                close(client)
                close(upstream)
                return
            }
            EgressProxy.setTimeout(client, seconds: 0)
            EgressProxy.setTimeout(upstream, seconds: 0)
            relay(client: client, upstream: upstream)
            return
        }
        guard let target = EgressProxy.parseAbsoluteHTTP(header: header) else {
            deny(client: client, host: "", port: 0, reason: "malformed")
            return
        }
        // Absolute-URI is the loopback-gateway shape (plaintext model
        // gateways, MCP servers): the cage reaches loopback directly, so
        // relaying grants no new capability. External plaintext stays
        // refused: the allowlist is HTTPS-only by design.
        guard policy.allowsLoopbackTarget(host: target.host, port: target.port) else {
            deny(client: client, host: target.host, port: target.port, reason: "denied-policy")
            return
        }
        guard let upstream = EgressProxy.dial(host: target.host, port: target.port) else {
            deny(client: client, host: target.host, port: target.port, reason: "dial-failed")
            return
        }
        EgressProxy.suppressSIGPIPE(upstream)
        // Origin servers accept absolute-URI (RFC 7230 5.3.2): forward the
        // request bytes unchanged, then relay both directions.
        guard EgressProxy.writeAll(upstream, bytes: Array(header.utf8) + leftover) else {
            close(client)
            close(upstream)
            return
        }
        EgressProxy.setTimeout(client, seconds: 0)
        EgressProxy.setTimeout(upstream, seconds: 0)
        relay(client: client, upstream: upstream)
    }

    private func deny(client: Int32, host: String, port: Int, reason: String) {
        _ = EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
        close(client)
        record(EgressProxyDenial(host: host, port: port, reason: reason, recordedAt: Date()))
    }

    private func relay(client: Int32, upstream: Int32) {
        let group = DispatchGroup()
        group.enter()
        relayQueue.async { [weak self] in
            EgressProxy.copy(from: client, to: upstream, shouldStop: { self?.isRunning() != true })
            group.leave()
        }
        group.enter()
        relayQueue.async { [weak self] in
            EgressProxy.copy(from: upstream, to: client, shouldStop: { self?.isRunning() != true })
            group.leave()
        }
        group.notify(queue: relayQueue) {
            shutdown(client, SHUT_RDWR)
            shutdown(upstream, SHUT_RDWR)
            close(client)
            close(upstream)
        }
    }

    /// CONNECT target from a header block. Strict: exactly `CONNECT
    /// host:port HTTP/1.x`, one colon, no userinfo, brackets, path, query,
    /// or whitespace. Returns nil for anything else.
    static func parseCONNECT(header: String) -> (host: String, port: Int)? {
        guard let lineEnd = header.range(of: "\r\n") else { return nil }
        let parts = header[..<lineEnd.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "CONNECT",
            parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else {
            return nil
        }
        let authority = String(parts[1])
        guard authority.isEmpty == false,
            authority.contains("@") == false,
            authority.contains("[") == false,
            authority.contains("]") == false,
            authority.contains("/") == false,
            authority.contains("?") == false,
            authority.contains("#") == false
        else {
            return nil
        }
        let segments = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 2 else { return nil }
        let host = segments[0]
        guard host.isEmpty == false, host.utf8.count <= 253 else { return nil }
        guard let port = Int(segments[1]), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    /// Absolute-URI request target from a header block (`POST
    /// http://127.0.0.1:10100/v1/messages HTTP/1.1`). Plain-HTTP clients
    /// (loopback gateways, MCP servers) speak this instead of CONNECT.
    /// Strict: http scheme only, ASCII-uppercase method, no userinfo or
    /// brackets, explicit or default (:80) port, HTTP/1.x. Policy decides
    /// relay vs deny; external targets parse but are never relayed.
    static func parseAbsoluteHTTP(header: String) -> (host: String, port: Int)? {
        guard let lineEnd = header.range(of: "\r\n") else { return nil }
        let parts = header[..<lineEnd.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard parts[0].isEmpty == false,
            parts[0].allSatisfy({ $0.asciiValue.map { $0 >= 65 && $0 <= 90 } ?? false })
        else {
            return nil
        }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        let target = String(parts[1])
        guard target.count > 7, target.lowercased().hasPrefix("http://") else { return nil }
        let rest = String(target.dropFirst(7))
        let authority = rest.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard authority.isEmpty == false,
            authority.contains("@") == false,
            authority.contains("[") == false,
            authority.contains("]") == false
        else {
            return nil
        }
        let segments = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard segments.count <= 2 else { return nil }
        let host = segments[0]
        guard host.isEmpty == false, host.utf8.count <= 253 else { return nil }
        if segments.count == 2 {
            guard let port = Int(segments[1]), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        return (host, 80)
    }

    private enum HeaderRead {
        case success(header: String, leftover: [UInt8])
        case oversized
        case failure
    }

    private static func readHeaders(_ fd: Int32, maximumBytes: Int) -> HeaderRead {
        var bytes = [UInt8]()
        bytes.reserveCapacity(4096)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < maximumBytes {
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(fd, base, pointer.count, 0)
            }
            if count <= 0 { return .failure }
            bytes.append(contentsOf: buffer[..<count])
            if let split = splitHeaders(bytes) {
                return .success(header: split.header, leftover: split.leftover)
            }
        }
        return .oversized
    }

    /// Header text through the first blank line plus any already-read bytes
    /// after it. A client that pipelines tunnel bytes with the CONNECT must
    /// not lose them. Non-UTF-8 headers never split and fail oversized
    /// instead: denied either way.
    private static func splitHeaders(_ bytes: [UInt8]) -> (header: String, leftover: [UInt8])? {
        guard bytes.count >= 4 else { return nil }
        for end in 4...bytes.count {
            let tail = bytes[(end - 4)..<end]
            if tail.elementsEqual([13, 10, 13, 10]) {
                guard let header = String(bytes: bytes[..<end], encoding: .utf8) else {
                    return nil
                }
                return (header, Array(bytes[end...]))
            }
        }
        return nil
    }

    private static func dial(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        memset(&hints, 0, MemoryLayout<addrinfo>.size)
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return nil
        }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            let fd = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            if fd >= 0 {
                if connectWithTimeout(fd, address: node.pointee.ai_addr, length: node.pointee.ai_addrlen, seconds: 10) {
                    return fd
                }
                close(fd)
            }
            current = node.pointee.ai_next
        }
        return nil
    }

    private static func connectWithTimeout(
        _ fd: Int32,
        address: UnsafePointer<sockaddr>?,
        length: socklen_t,
        seconds: Int
    ) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }
        let result = connect(fd, address, length)
        if result == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return true
        }
        guard errno == EINPROGRESS else { return false }
        var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&item, 1, Int32(seconds * 1000))
        guard ready > 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            return false
        }
        _ = fcntl(fd, F_SETFL, flags)
        return true
    }

    private static func copy(from source: Int32, to destination: Int32, shouldStop: @escaping () -> Bool) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while shouldStop() == false {
            var item = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            if item.revents & Int16(POLLERR | POLLNVAL) != 0 { break }
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(source, base, pointer.count, 0)
            }
            if count <= 0 { break }
            if writeAll(destination, bytes: Array(buffer[..<count])) == false { break }
            if item.revents & Int16(POLLHUP) != 0 { break }
        }
        shutdown(source, SHUT_RD)
        shutdown(destination, SHUT_WR)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, bytes: [UInt8]) -> Bool {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return send(fd, base.advanced(by: offset), bytes.count - offset, flags)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// A `send` on a closed peer must fail, not kill the host with SIGPIPE.
    /// Linux sends with MSG_NOSIGNAL per call instead.
    private static func suppressSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func port(of address: UnsafePointer<sockaddr>) -> UInt16 {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socket in
                UInt16(bigEndian: socket.pointee.sin_port)
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { socket in
                UInt16(bigEndian: socket.pointee.sin6_port)
            }
        default:
            return 0
        }
    }

    private static let denialLogLock = Mutex<Void>(())

    private static func productionDenialLog() -> @Sendable (EgressProxyDenial) -> Void {
        { denial in
            denialLogLock.withLock { _ in
                writeDenial(denial)
            }
        }
    }

    private static func writeDenial(_ denial: EgressProxyDenial) {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            home.hasPrefix("/"), home.contains("\0") == false
        else {
            return
        }
        let url = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("egress-denials.jsonl", isDirectory: false)
        let record = [
            "host": denial.host,
            "port": String(denial.port),
            "reason": denial.reason,
            "recordedAt": String(denial.recordedAt.timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
            let line = String(data: data, encoding: .utf8)
        else {
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
