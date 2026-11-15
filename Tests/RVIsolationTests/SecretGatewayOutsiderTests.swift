#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// A peer is a member of the runtime only when its client port was marked.
private final class MarkedPorts: Sendable {
    let ports = Mutex<Set<UInt16>>([])

    var check: GatewayPeerCheck {
        GatewayPeerCheck { peer, _ in self.ports.withLock { $0.contains(peer.port) } ? .member : .outsider }
    }
}

/// A loopback client socket bound before it connects, so its port is known first.
private func boundClient() throws -> (fd: Int32, port: UInt16) {
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
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var name = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &name) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    if bound != 0 || named != 0 { close(fd) }
    try #require(bound == 0 && named == 0)
    return (fd, UInt16(bigEndian: name.sin_port))
}

private func dial(_ fd: Int32, to port: Int) throws {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(connected == 0)
}

/// Connects and resets the connection at once, recording nothing when
/// either fails. A reset leaves no port waiting out TIME_WAIT, and one
/// that lands before the gateway accepts makes its `accept` fail.
private func connectAndHangUp(_ port: Int) {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return }
    defer { close(fd) }
    var reset = linger(l_onoff: 1, l_linger: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

/// What the gateway wrote before it closed the connection.
private func answer(_ fd: Int32) -> String {
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

private func eventually(within seconds: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while condition() == false {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// Connections from a process in none of the registered runtimes are told
/// apart before their first byte is read.
@Suite("SecretGatewayOutsider")
struct SecretGatewayOutsiderTests {
    private func gateway(
        _ check: GatewayPeerCheck, upstream: RecordingUpstream, audit: AuditRecords
    ) throws -> (SecretGateway, SecretPlaceholder) {
        let gateway = SecretGateway(transport: upstream.transport, peers: check, audit: audit.record)
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", value: try #require(SecretValue("sk-live-REAL-0123456789")),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: "R1",
            surfaces: [.header], processGroup: testProcessGroup))
        return (gateway, placeholder)
    }

    private func bearer(_ placeholder: SecretPlaceholder) -> [UInt8] {
        Array("GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n".utf8)
    }

    /// Every connection slot taken by outsiders that send nothing: they hold
    /// none of the runtime's slots, past their own few they are answered
    /// `503` unread and unaudited, and a request from the runtime is served.
    @Test(.timeLimit(.minutes(1)))
    func outsidersHoldNoSlotsOfTheRuntimes() throws {
        let marked = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(marked.check, upstream: upstream, audit: audit)
        gateway.outsiderHeadDeadline = 30
        gateway.requestHeadDeadline = 30
        let port = try gateway.start().get()
        defer { gateway.stop() }
        let outsiders = try (0..<SecretGateway.maximumConnections).map { _ in try boundClient().fd }
        defer { outsiders.forEach { close($0) } }
        for fd in outsiders { try dial(fd, to: port) }
        let turnedAway = SecretGateway.maximumConnections - SecretGateway.outsiderConnections
        #expect(eventually { outsiders.filter(readable).count == turnedAway })
        let answers = outsiders.filter(readable).map(answer)
        #expect(answers.allSatisfy { $0.hasPrefix("HTTP/1.1 503") && $0.contains("gateway busy") }, "\(answers.prefix(2))")

        let member = try boundClient()
        defer { close(member.fd) }
        marked.ports.withLock { _ = $0.insert(member.port) }
        try dial(member.fd, to: port)
        #expect(GatewaySocket.writeAll(member.fd, bearer(placeholder)))
        #expect(answer(member.fd).hasPrefix("HTTP/1.1 200"))
        #expect(upstream.requests.count == 1)
        #expect(outsiders.filter(readable).count == turnedAway, "an outsider holding a slot was answered")
        #expect(audit.items.withLock { $0.allSatisfy { $0.refusal == nil } })
    }

    /// Outsiders that take long to tell apart hold every classifier, and
    /// more wait behind them: a member that connects meanwhile waits its
    /// turn and is served. It never takes a slot an outsider could hold.
    @Test(.timeLimit(.minutes(1)))
    func outsidersSlowToTellApartDelayAMemberButNeverTurnItAway() throws {
        let marked = MarkedPorts()
        let slow = GatewayPeerCheck { peer, _ in
            if marked.ports.withLock({ $0.contains(peer.port) }) { return .member }
            Thread.sleep(forTimeInterval: 0.2)
            return .outsider
        }
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(slow, upstream: upstream, audit: audit)
        gateway.outsiderHeadDeadline = 30
        let port = try gateway.start().get()
        defer { gateway.stop() }
        let outsiders = try (0..<SecretGateway.maximumConnections).map { _ in try boundClient().fd }
        defer { outsiders.forEach { close($0) } }
        for fd in outsiders { try dial(fd, to: port) }
        let member = try boundClient()
        defer { close(member.fd) }
        marked.ports.withLock { _ = $0.insert(member.port) }
        try dial(member.fd, to: port)
        #expect(GatewaySocket.writeAll(member.fd, bearer(placeholder)))
        let served = answer(member.fd)
        #expect(served.hasPrefix("HTTP/1.1 200"), "\(served.prefix(80))")
        #expect(upstream.requests.count == 1)
    }

    /// Outsiders connecting and hanging up as fast as they can, while a
    /// member sends one request after another: every one is served.
    @Test(.timeLimit(.minutes(1)))
    func outsidersHammeringTheGatewayNeverTurnAwayAMember() throws {
        let marked = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(marked.check, upstream: upstream, audit: audit)
        let port = try gateway.start().get()
        defer { gateway.stop() }
        let stop = Atomic<Bool>(false)
        let hammers = DispatchGroup()
        for _ in 0..<16 {
            hammers.enter()
            Thread.detachNewThread {
                defer { hammers.leave() }
                while stop.load(ordering: .relaxed) == false { connectAndHangUp(port) }
            }
        }
        var statuses: [String] = []
        for _ in 0..<20 {
            let member = try boundClient()
            marked.ports.withLock { _ = $0.insert(member.port) }
            try dial(member.fd, to: port)
            #expect(GatewaySocket.writeAll(member.fd, bearer(placeholder)))
            statuses.append(String(answer(member.fd).prefix(12)))
            close(member.fd)
        }
        stop.store(true, ordering: .relaxed)
        _ = hammers.wait(timeout: .now() + 10)
        #expect(statuses.allSatisfy { $0 == "HTTP/1.1 200" }, "\(statuses)")
        #expect(upstream.requests.count == 20)
    }

    /// Outside every runtime when it connected, inside one by the time its
    /// placeholder is checked: still refused, and nothing is forwarded.
    @Test(.timeLimit(.minutes(1)))
    func anOutsiderFoundInTheRuntimeLaterIsStillRefused() throws {
        let checked = MarkedPorts()
        let flips = GatewayPeerCheck { peer, _ in
            checked.ports.withLock { $0.insert(peer.port).inserted } ? .outsider : .member
        }
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(flips, upstream: upstream, audit: audit)
        let port = try gateway.start().get()
        defer { gateway.stop() }
        let client = try boundClient()
        defer { close(client.fd) }
        try dial(client.fd, to: port)
        #expect(GatewaySocket.writeAll(client.fd, bearer(placeholder)))
        #expect(answer(client.fd).hasPrefix("HTTP/1.1 403"))
        #expect(upstream.requests.isEmpty)
        #expect(audit.items.withLock { $0.last?.refusal?.code } == "runtimeUnverified")
    }

    /// An outsider has `outsiderHeadDeadline` for its head, a member the
    /// longer `requestHeadDeadline`: the outsider is answered `408` while
    /// the member's connection is still open.
    @Test(.timeLimit(.minutes(1)))
    func anOutsiderHasTheShorterHeadDeadline() throws {
        let marked = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, _) = try gateway(marked.check, upstream: upstream, audit: audit)
        gateway.outsiderHeadDeadline = 0.5
        gateway.requestHeadDeadline = 30
        let port = try gateway.start().get()
        defer { gateway.stop() }
        let (member, outsider) = (try boundClient(), try boundClient())
        defer { close(member.fd); close(outsider.fd) }
        marked.ports.withLock { _ = $0.insert(member.port) }
        for client in [member, outsider] {
            try dial(client.fd, to: port)
            #expect(GatewaySocket.writeAll(client.fd, Array("GET /s/OPENAI_API_KEY".utf8)))
        }
        #expect(eventually { readable(outsider.fd) })
        #expect(readable(member.fd) == false, "the member was answered at the outsider's deadline")
        let refused = answer(outsider.fd)
        #expect(refused.hasPrefix("HTTP/1.1 408"), "\(refused.prefix(80))")
        #expect(refused.contains("the request did not arrive in time"))
        #expect(audit.items.withLock { $0.last?.refusal?.code } == "requestTimeout")
        #expect(upstream.requests.isEmpty)
    }
}
