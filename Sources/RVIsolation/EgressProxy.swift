#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import Synchronization

/// Why one CONNECT was denied. Raw values are the `egress-denials.jsonl`
/// spellings: existing values are preserved, and the old catch-all
/// `dial-failed` now covers only connect failures (DNS and filter
/// refusals record precisely).
public enum EgressDenialReason: String, Sendable, Equatable, CaseIterable {
    case headerTooLarge = "header-too-large"
    case deniedPolicy = "denied-policy"
    case malformed = "malformed"
    case dnsFailed = "dns-failed"
    case addressFiltered = "address-filtered"
    case dialFailed = "dial-failed"
    /// The listener requires a client credential and this connection did not present it.
    case unauthenticated = "unauthenticated"
    /// The TLS ClientHello named a different server than the CONNECT
    /// authority (or was not TLS with an SNI at all).
    case sniMismatch = "sni-mismatch"
}

/// One denied CONNECT, recorded for the allowlist learning loop.
public struct EgressProxyDenial: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var reason: EgressDenialReason
    public var recordedAt: Date

    public init(host: String, port: Int, reason: EgressDenialReason, recordedAt: Date) {
        self.host = host
        self.port = port
        self.reason = reason
        self.recordedAt = recordedAt
    }
}

/// Why the egress proxy could not bind. Carries the phase plus the errno
/// (or EAI code) observed there. Callers fail closed; the value exists for
/// diagnostics and tests.
public enum EgressStartError: Error, Sendable, Equatable {
    /// `getaddrinfo("127.0.0.1", "0")` failed; the code is the EAI result.
    case resolveLoopbackFailed(code: Int32)
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case addressFailed(errno: Int32)
}

/// One dial attempt's outcome. The proxy denies the CONNECT either way;
/// the cases exist so tests pin the filter and callers can tell DNS
/// failure from policy filtering from refused connections.
enum DialOutcome: Sendable, Equatable {
    case connected(Int32)
    /// No address resolved.
    case dnsFailed
    /// Every resolved address failed the public-unicast filter.
    case addressFiltered
    /// A usable address existed but socket or connect failed on all of them.
    case connectFailed
}

/// HTTP CONNECT proxy for contained agent runtimes.
///
/// Binds 127.0.0.1 on an ephemeral port; the cage reaches it through the
/// seatbelt `localhost` rule and can dial nothing else directly. Each
/// CONNECT is admitted by `EgressHostPolicy` (generic public web hosts
/// in Standard mode, or loopback targets on any port) and resolved here,
/// host-side: clients never supply IPs, and non-public addresses never
/// relay. Denials are logged; allowed streams relay as opaque bytes. One
/// proxy per workspace host; `stop` ends new accepts and lets in-flight
/// relays drain.
public final class EgressProxy: @unchecked Sendable {
    private let policy: EgressHostPolicy
    private let record: @Sendable (EgressProxyDenial) -> Void
    /// When set, CONNECT and absolute-URI requests must present this secret
    /// as `Proxy-Authorization: Basic` for `rv:<credential>`. An open
    /// 127.0.0.1 listener is otherwise a relay for any local client.
    private let clientCredential: String?
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "rv.egress.accept", qos: .userInitiated)
    private let relayQueue = DispatchQueue(
        label: "rv.egress.relay", qos: .userInitiated, attributes: .concurrent
    )

    public init(
        policy: EgressHostPolicy = .publicHTTPS,
        record: (@Sendable (EgressProxyDenial) -> Void)? = nil,
        clientCredential: String? = nil
    ) {
        self.policy = policy
        self.record = record ?? EgressProxy.productionDenialLog()
        self.clientCredential = clientCredential
    }

    /// Bound port after `start` succeeds.
    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    private var boundPort: Int = 0

    /// Bind 127.0.0.1:0, listen, and serve until `stop`. Returns the bound
    /// port, or the phase plus errno when the socket cannot be established
    /// (fail closed: without a proxy the cage has no route out at all).
    /// Starting a running proxy returns the bound port again.
    public func start() -> Result<Int, EgressStartError> {
        lock.lock()
        if running {
            let port = boundPort
            lock.unlock()
            return .success(port)
        }
        lock.unlock()
        var hints = addrinfo()
        memset(&hints, 0, MemoryLayout<addrinfo>.size)
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var info: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo("127.0.0.1", "0", &hints, &info)
        guard gai == 0, let first = info else {
            return .failure(.resolveLoopbackFailed(code: gai))
        }
        defer { freeaddrinfo(first) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return .failure(.socketFailed(errno: errno)) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            let code = errno
            close(fd)
            return .failure(.bindFailed(errno: code))
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            return .failure(.listenFailed(errno: code))
        }
        var name = sockaddr_storage()
        var nameLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var savedErrno: Int32 = 0
        let bound: Int = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                guard getsockname(fd, address, &nameLength) == 0 else {
                    savedErrno = errno
                    return 0
                }
                return Int(EgressProxy.port(of: address))
            }
        }
        guard bound > 0 else {
            close(fd)
            return .failure(.addressFailed(errno: savedErrno))
        }
        lock.lock()
        listenFD = fd
        boundPort = bound
        running = true
        lock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return .success(bound)
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        boundPort = 0
        lock.unlock()
        // shutdown() first: close() alone does not wake the thread blocked
        // in accept() on Darwin, which would park it (and the listening
        // socket) for the life of the process.
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
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
            var acceptError: Int32 = 0
            let fd: Int32 = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    lock.lock()
                    let listen = listenFD
                    lock.unlock()
                    guard listen >= 0 else { return Int32(-1) }
                    let accepted = accept(listen, address, &peerLength)
                    if accepted < 0 { acceptError = errno }
                    return accepted
                }
            }
            guard fd >= 0 else {
                if isRunning() {
                    // Accept failures are abnormal; surface the errno instead
                    // of spinning silently (under load these would otherwise
                    // surface only as client-side timeouts).
                    Self.complain("rv.egress: accept failed errno=\(acceptError)")
                    usleep(50_000)
                }
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
            deny(client: client, host: "", port: 0, reason: .headerTooLarge)
            return
        case .success(let header, let leftover):
            serveRequest(client: client, header: header, leftover: leftover)
        }
    }

    private func serveRequest(client: Int32, header: String, leftover: [UInt8]) {
        if let credential = clientCredential {
            let expected = "rv:\(credential)"
            let presented = EgressProxy.basicProxyCredential(header) ?? ""
            guard EgressProxy.constantTimeEquals(presented, expected) else {
                deny(client: client, host: "", port: 0, reason: .unauthenticated)
                return
            }
        }
        if let target = EgressProxy.parseCONNECT(header: header) {
            let external = policy.allows(host: target.host, port: target.port)
            let loopback = policy.allowsLoopbackTarget(host: target.host, port: target.port)
            guard external || loopback else {
                deny(client: client, host: target.host, port: target.port, reason: .deniedPolicy)
                return
            }
            // The credentialed (per-server sandbox) proxy binds the tunnel
            // to the TLS origin it dials: a CONNECT to an allowed host must
            // carry a ClientHello whose SNI is that host, so a co-hosted
            // tenant on the same address is not reachable through it. The
            // 200 goes first (clients wait for it before starting TLS),
            // then the first record is read and checked before dialing.
            var hello = leftover
            if clientCredential != nil, external {
                guard EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)) else {
                    close(client)
                    return
                }
                guard let first = EgressProxy.readClientHello(client: client, initial: leftover),
                    let serverName = EgressProxy.tlsServerName(first),
                    serverName.lowercased() == target.host.lowercased()
                else {
                    close(client)
                    record(EgressProxyDenial(host: target.host, port: target.port, reason: .sniMismatch, recordedAt: Date()))
                    return
                }
                hello = first
            }
            let established = clientCredential != nil && external
            guard
                let upstream = dialUpstream(
                    host: target.host,
                    port: target.port,
                    external: external,
                    client: client,
                    established: established
                )
            else {
                return
            }
            EgressProxy.suppressSIGPIPE(upstream)
            guard (established || EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))),
                hello.isEmpty || EgressProxy.writeAll(upstream, bytes: hello)
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
            deny(client: client, host: "", port: 0, reason: .malformed)
            return
        }
        // The credentialed sandbox proxy is CONNECT-only: its allowlist is
        // port 443, so absolute-URI could only speak plaintext to a TLS
        // port — never a capability a caged server needs.
        if clientCredential != nil, policy.allows(host: target.host, port: target.port) {
            deny(client: client, host: target.host, port: target.port, reason: .deniedPolicy)
            return
        }
        // Absolute-URI is the plaintext shape: loopback gateways and
        // servers (the cage reaches loopback directly, so relaying grants
        // no new capability) plus public port-80 traffic under the same
        // policy and public-unicast dial filter as CONNECT. Tunneling
        // plaintext grants no capability that tunneling TLS does not.
        let external = policy.allows(host: target.host, port: target.port)
        let loopback = policy.allowsLoopbackTarget(host: target.host, port: target.port)
        guard external || loopback else {
            deny(client: client, host: target.host, port: target.port, reason: .deniedPolicy)
            return
        }
        guard
            let upstream = dialUpstream(
                host: target.host,
                port: target.port,
                external: external,
                client: client
            )
        else {
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

    private func deny(client: Int32, host: String, port: Int, reason: EgressDenialReason) {
        _ = EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
        close(client)
        record(EgressProxyDenial(host: host, port: port, reason: reason, recordedAt: Date()))
    }

    /// Dials for a relay, denying with the precise reason on failure.
    /// Returns nil after denying; shared by the CONNECT and absolute-URI
    /// paths so the outcome mapping lives in one place. Once a CONNECT is
    /// established (the SNI-checked path already sent 200), failure just
    /// closes: a 403 written into a live tunnel is meaningless bytes.
    private func dialUpstream(host: String, port: Int, external: Bool, client: Int32, established: Bool = false) -> Int32? {
        let reason: EgressDenialReason
        switch EgressProxy.dial(host: host, port: port, external: external) {
        case .connected(let fd):
            return fd
        case .dnsFailed:
            reason = .dnsFailed
        case .addressFiltered:
            reason = .addressFiltered
        case .connectFailed:
            reason = .dialFailed
        }
        if established {
            close(client)
            record(EgressProxyDenial(host: host, port: port, reason: reason, recordedAt: Date()))
        } else {
            deny(client: client, host: host, port: port, reason: reason)
        }
        return nil
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
            shutdown(client, Int32(SHUT_RDWR))
            shutdown(upstream, Int32(SHUT_RDWR))
            close(client)
            close(upstream)
        }
    }

    /// `Proxy-Authorization: Basic` decoded as text, or nil when the header is absent.
    /// A present but unusable header is an empty string, which never matches.
    static func basicProxyCredential(_ header: String) -> String? {
        var found = false
        var decoded = ""
        for line in header.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.lowercased() == "proxy-authorization" else { continue }
            found = true
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].lowercased() == "basic",
                let data = Data(base64Encoded: String(parts[1])),
                let text = String(data: data, encoding: .utf8)
            else {
                decoded = ""
                continue
            }
            decoded = text
        }
        return found ? decoded : nil
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
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
            var readError: Int32 = 0
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                let received = recv(fd, base, pointer.count, 0)
                if received < 0 { readError = errno }
                return received
            }
            if count < 0 {
                if readError == EINTR { continue }
                return .failure
            }
            if count == 0 { return .failure }
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

    /// Dial one relay upstream. `external == false` skips the
    /// public-unicast filter entirely, so it is only valid for hosts the
    /// policy already admitted via `allowsLoopbackTarget`; passing an
    /// unadmitted host here would let a DNS-rebinding attacker reach
    /// loopback, LAN, or metadata endpoints.
    static func dial(host: String, port: Int, external: Bool) -> DialOutcome {
        var hints = addrinfo()
        memset(&hints, 0, MemoryLayout<addrinfo>.size)
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return .dnsFailed
        }
        defer { freeaddrinfo(first) }
        var sawUsable = false
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            // A compromised resolver must not rebind an allowlisted name
            // onto loopback, LAN, link-local, or metadata addresses and
            // have the proxy relay there. The filtered sockaddr is the one
            // we would connect, so there is no check-to-use race.
            if external, isPublicUnicast(node.pointee.ai_addr) == false {
                current = node.pointee.ai_next
                continue
            }
            // Loopback relays are filtered too: the *name* was admitted, so
            // whatever it resolves to must actually be loopback.
            if external == false, isLoopbackAddress(node.pointee.ai_addr) == false {
                current = node.pointee.ai_next
                continue
            }
            sawUsable = true
            let fd = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            if fd >= 0 {
                if connectWithTimeout(fd, address: node.pointee.ai_addr, length: node.pointee.ai_addrlen, seconds: 10) {
                    return .connected(fd)
                }
                close(fd)
            }
            current = node.pointee.ai_next
        }
        return sawUsable ? .connectFailed : .addressFiltered
    }

    /// True when `address` is a globally routable unicast destination.
    /// Rejects loopback, unspecified, private, link-local, site-local,
    /// multicast, reserved, documentation, and benchmarking ranges,
    /// recursing into the embedded IPv4 of mapped, compatible, and 6to4
    /// addresses. Unknown families fail closed.
    static func isPublicUnicast(_ address: UnsafePointer<sockaddr>?) -> Bool {
        guard let address else { return false }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socket in
                isPublicIPv4(UInt32(bigEndian: socket.pointee.sin_addr.s_addr))
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { socket in
                withUnsafeBytes(of: socket.pointee.sin6_addr) { raw in
                    isPublicIPv6(raw)
                }
            }
        default:
            return false
        }
    }

    /// True when `address` is in 127.0.0.0/8 or is ::1 (including the
    /// IPv4-mapped spelling). Unknown families fail closed.
    static func isLoopbackAddress(_ address: UnsafePointer<sockaddr>?) -> Bool {
        guard let address else { return false }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socket in
                (UInt32(bigEndian: socket.pointee.sin_addr.s_addr) >> 24) == 127
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { socket in
                withUnsafeBytes(of: socket.pointee.sin6_addr) { raw in
                    guard raw.count == 16 else { return false }
                    let bytes = (0..<16).map { raw[$0] }
                    if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
                    if Array(bytes.prefix(12)) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] {
                        return bytes[12] == 127
                    }
                    return false
                }
            }
        default:
            return false
        }
    }

    private static func isPublicIPv4(_ hostOrder: UInt32) -> Bool {
        func contains(_ base: UInt32, _ bits: UInt32) -> Bool {
            let mask: UInt32 = bits == 0 ? 0 : (~UInt32(0) << (32 - bits))
            return hostOrder & mask == base & mask
        }
        // Unspecified, loopback, private, CGNAT, link-local (covers the
        // 169.254.169.254 metadata endpoint), multicast, reserved.
        let denied: [(UInt32, UInt32)] = [
            (0x00000000, 8), (0x7F000000, 8),
            (0x0A000000, 8), (0xAC100000, 12), (0xC0A80000, 16),
            (0x64400000, 10), (0xA9FE0000, 16),
            (0xE0000000, 4), (0xF0000000, 4),
            // Documentation and benchmarking: never a real API endpoint.
            (0xC0000200, 24), (0xC6336400, 24), (0xCB007100, 24),
            (0xC6120000, 15),
        ]
        return denied.allSatisfy { contains($0.0, $0.1) == false }
    }

    private static func isPublicIPv6(_ raw: UnsafeRawBufferPointer) -> Bool {
        guard raw.count == 16 else { return false }
        let bytes = (0..<16).map { raw[$0] }
        if bytes.allSatisfy({ $0 == 0 }) { return false } // ::
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false } // ::1
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false } // fe80::/10
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return false } // fec0::/10 deprecated site-local
        if bytes[0] & 0xFE == 0xFC { return false } // fc00::/7
        if bytes[0] == 0xFF { return false } // ff00::/8
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
            return false // 2001:db8::/32 documentation
        }
        if bytes[0] == 0x01, bytes[1] == 0x00, bytes[2] == 0, bytes[3] == 0, bytes[4] == 0, bytes[5] == 0, bytes[6] == 0, bytes[7] == 0 {
            return false // 100::/64 discard-only
        }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x02 {
            return false // 2001:2::/48 benchmarking
        }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 {
            return false // 2001::/32 Teredo (embeds an obfuscated IPv4)
        }
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B {
            if bytes[4] == 0x00, bytes[5] == 0x01 {
                return false // 64:ff9b:1::/48 local-use NAT64
            }
            if bytes[4...11].allSatisfy({ $0 == 0 }) {
                // 64:ff9b::/96 well-known NAT64: on a DNS64 network a rebound
                // A record synthesizes this form, so the embedded IPv4 decides.
                return isPublicIPv4(v4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            return false
        }
        if Array(bytes.prefix(12)) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] {
            return isPublicIPv4(v4(bytes[12], bytes[13], bytes[14], bytes[15])) // ::ffff:0:0/96
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
            // ::/96 deprecated IPv4-compatible (:: and ::1 already rejected).
            return isPublicIPv4(v4(bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 { // 2002::/16 6to4
            return isPublicIPv4(v4(bytes[2], bytes[3], bytes[4], bytes[5]))
        }
        return true
    }

    private static func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
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

    /// Reads exactly one TLS record (the ClientHello) from a just-established
    /// CONNECT client, starting from bytes already read past the headers.
    /// The client's 10-second socket timeout bounds the wait. Nil on EOF,
    /// error, a non-handshake first byte, or an oversized record.
    static func readClientHello(client: Int32, initial: [UInt8]) -> [UInt8]? {
        var bytes = initial
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if bytes.count >= 5 {
                guard bytes[0] == 0x16 else { return nil }
                let length = Int(bytes[3]) << 8 | Int(bytes[4])
                guard length <= 16_384 else { return nil }
                if bytes.count >= 5 + length { return bytes }
            }
            guard bytes.count <= 16_389 else { return nil }
            let count = chunk.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(client, base, pointer.count, 0)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            bytes += chunk[..<count]
        }
    }

    /// The SNI host_name of a TLS ClientHello record, parsed with every
    /// length checked against the buffer. Nil for anything malformed,
    /// truncated, or without a host_name — callers fail closed.
    static func tlsServerName(_ bytes: [UInt8]) -> String? {
        func at(_ index: Int) -> UInt8? { bytes.indices.contains(index) ? bytes[index] : nil }
        func u16(_ index: Int) -> Int? {
            guard let high = at(index), let low = at(index + 1) else { return nil }
            return Int(high) << 8 | Int(low)
        }
        guard at(0) == 0x16, let recordLength = u16(3), bytes.count >= 5 + recordLength else { return nil }
        guard at(5) == 0x01 else { return nil }
        var cursor = 5 + 4 + 2 + 32 // handshake header, client version, random
        guard let sessionLength = at(cursor).map(Int.init) else { return nil }
        cursor += 1 + sessionLength
        guard let suitesLength = u16(cursor) else { return nil }
        cursor += 2 + suitesLength
        guard let compressionLength = at(cursor).map(Int.init) else { return nil }
        cursor += 1 + compressionLength
        guard let extensionsLength = u16(cursor) else { return nil }
        cursor += 2
        let extensionsEnd = cursor + extensionsLength
        guard extensionsEnd <= 5 + recordLength else { return nil }
        while cursor + 4 <= extensionsEnd {
            guard let kind = u16(cursor), let length = u16(cursor + 2) else { return nil }
            let dataStart = cursor + 4
            let dataEnd = dataStart + length
            guard dataEnd <= extensionsEnd else { return nil }
            if kind == 0x0000 {
                guard let listLength = u16(dataStart) else { return nil }
                var entry = dataStart + 2
                let listEnd = entry + listLength
                guard listEnd <= dataEnd else { return nil }
                while entry + 3 <= listEnd {
                    guard let nameType = at(entry), let nameLength = u16(entry + 1) else { return nil }
                    let nameStart = entry + 3
                    let nameEnd = nameStart + nameLength
                    guard nameEnd <= listEnd else { return nil }
                    if nameType == 0 {
                        let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                        return name.isEmpty ? nil : name
                    }
                    entry = nameEnd
                }
                return nil
            }
            cursor = dataEnd
        }
        return nil
    }

    private static func copy(from source: Int32, to destination: Int32, shouldStop: @escaping () -> Bool) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        // Idle bound: a tunnel neither side speaks on for an hour is
        // closed instead of holding its descriptors forever.
        var idlePolls = 0
        while shouldStop() == false {
            var item = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                idlePolls += 1
                if idlePolls >= 3600 { break }
                continue
            }
            idlePolls = 0
            if item.revents & Int16(POLLERR | POLLNVAL) != 0 { break }
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(source, base, pointer.count, 0)
            }
            if count <= 0 { break }
            if writeAll(destination, bytes: Array(buffer[..<count])) == false { break }
            if item.revents & Int16(POLLHUP) != 0 { break }
        }
        shutdown(source, Int32(SHUT_RD))
        shutdown(destination, Int32(SHUT_WR))
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

    private static func complain(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static let denialLogLock = Mutex<Void>(())

    private static func productionDenialLog() -> @Sendable (EgressProxyDenial) -> Void {
        { denial in
            denialLogLock.withLock { _ in
                recordDenial(denial)
            }
        }
    }

    private static func recordDenial(_ denial: EgressProxyDenial) {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            home.hasPrefix("/"), home.contains("\0") == false
        else {
            complain("rv.egress: denial log skipped (HOME unavailable) host=\(denial.host) reason=\(denial.reason.rawValue)")
            return
        }
        let url = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("egress-denials.jsonl", isDirectory: false)
        _ = writeDenial(denial, to: url, diagnose: complain)
    }

    /// Appends one denial line to `url`. Returns true only when the line is
    /// persisted. Every failure path reports through `diagnose` (stderr in
    /// production) instead of dropping the record silently: the CONNECT was
    /// already denied either way, so enforcement stays fail-closed and only
    /// the audit persistence can fail.
    @discardableResult
    static func writeDenial(
        _ denial: EgressProxyDenial,
        to url: URL,
        diagnose: (String) -> Void
    ) -> Bool {
        let record = [
            "host": denial.host,
            "port": String(denial.port),
            "reason": denial.reason.rawValue,
            "recordedAt": String(denial.recordedAt.timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
            let line = String(data: data, encoding: .utf8)
        else {
            diagnose("rv.egress: denial log encode failed host=\(denial.host) reason=\(denial.reason.rawValue)")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            diagnose("rv.egress: denial log directory failed path=\(url.path) error=\(error.localizedDescription)")
            return false
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            do {
                try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                diagnose("rv.egress: denial log create failed path=\(url.path) error=\(error.localizedDescription)")
                return false
            }
        }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            diagnose("rv.egress: denial log append failed path=\(url.path) error=\(error.localizedDescription)")
            try? handle.close()
            return false
        }
        do {
            try handle.close()
        } catch {
            diagnose("rv.egress: denial log close failed path=\(url.path) error=\(error.localizedDescription)")
            return false
        }
        return true
    }
}
