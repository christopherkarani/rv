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
/// Every port the gateway checked is kept in `seen`.
private final class MarkedPorts: Sendable {
    let ports = Mutex<Set<UInt16>>([])
    let seen = Mutex<Set<UInt16>>([])

    var check: GatewayPeerCheck {
        GatewayPeerCheck { peer, _ in
            self.seen.withLock { _ = $0.insert(peer.port) }
            return self.ports.withLock { $0.contains(peer.port) } ? .member : .outsider
        }
    }
}

/// Set once the hammering threads should stop.
private final class StopFlag: Sendable {
    let raised = Atomic<Bool>(false)
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

/// A member's connection, marked before it dials, dialled again while the
/// kernel refuses it (a full listen backlog), for up to 20 s.
private func dialAgainWhileRefused(_ port: Int, marked: MarkedPorts) throws -> (fd: Int32, port: UInt16) {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        let member = try boundClient()
        marked.ports.withLock { _ = $0.insert(member.port) }
        // A hammer's earlier connection may have used this port; none can
        // while the member holds it.
        marked.seen.withLock { _ = $0.remove(member.port) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(member.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected == 0 { return member }
        close(member.fd)
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw POSIXError(.ECONNREFUSED)
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
    /// 0.1 s each, 8 at a time: the member waits about 0.8 s, well inside
    /// the 10 s its answer is read for (the wait for a classifier does not
    /// count against its head deadline).
    @Test(.timeLimit(.minutes(1)))
    func outsidersSlowToTellApartDelayAMemberButNeverTurnItAway() throws {
        let marked = MarkedPorts()
        let slow = GatewayPeerCheck { peer, _ in
            if marked.ports.withLock({ $0.contains(peer.port) }) { return .member }
            Thread.sleep(forTimeInterval: 0.1)
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
    /// member sends one request after another: every one is served. They
    /// can fill the listen backlog, and the kernel then refuses the member's
    /// connection before the gateway sees it, or drops it after the member's
    /// `connect` returned (the member then reads nothing), so the member
    /// dials again. A connection the gateway checked and did not answer,
    /// or any answer but 200, fails: the gateway itself never turns it away.
    @Test(.timeLimit(.minutes(1)))
    func outsidersHammeringTheGatewayNeverTurnAwayAMember() throws {
        let marked = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(marked.check, upstream: upstream, audit: audit)
        let port = try gateway.start().get()
        defer { gateway.stop() }
        let stop = StopFlag()
        let hammers = DispatchGroup()
        for _ in 0..<16 {
            hammers.enter()
            Thread.detachNewThread {
                defer { hammers.leave() }
                while stop.raised.load(ordering: .relaxed) == false { connectAndHangUp(port) }
            }
        }
        var statuses: [String] = []
        var dropped = 0
        let deadline = Date().addingTimeInterval(30)
        while statuses.count < 20, Date() < deadline {
            let member = try dialAgainWhileRefused(port, marked: marked)
            _ = GatewaySocket.writeAll(member.fd, bearer(placeholder))
            let status = String(answer(member.fd).prefix(12))
            close(member.fd)
            if status.isEmpty, marked.seen.withLock({ $0.contains(member.port) }) == false {
                dropped += 1
                continue
            }
            statuses.append(status.isEmpty ? "checked, unanswered" : status)
        }
        #expect(statuses.count == 20, "\(dropped) dropped by the kernel")
        stop.raised.store(true, ordering: .relaxed)
        _ = hammers.wait(timeout: .now() + 10)
        #expect(statuses.allSatisfy { $0 == "HTTP/1.1 200" }, "\(statuses)")
        #expect(upstream.requests.count == 20)
    }

    /// A client that resets its connection after the gateway accepted it
    /// but before it was set up. Darwin then refuses `SO_NOSIGPIPE` on that
    /// socket, and any answer written to it raised SIGPIPE, which killed the
    /// gateway's whole process. It is closed unanswered, unaudited on Darwin,
    /// and the next client is served.
    @Test(.timeLimit(.minutes(1)))
    func aClientResetBeforeItsConnectionIsSetUpIsClosedUnanswered() throws {
        let marked = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(marked.check, upstream: upstream, audit: audit)
        let paused = StopFlag()
        let accepted = DispatchSemaphore(value: 0)
        let reset = DispatchSemaphore(value: 0)
        gateway.afterAccept = { client in
            guard paused.raised.exchange(true, ordering: .relaxed) == false else { return }
            accepted.signal()
            _ = reset.wait(timeout: .now() + 10)
            // The reset has arrived once the socket is readable (its error
            // pending), instead of after a guessed sleep.
            var state = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            _ = poll(&state, 1, 10_000)
        }
        let port = try gateway.start().get()
        defer { gateway.stop() }
        #if canImport(Darwin)
        let resetting = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let resetting = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        try #require(resetting >= 0)
        var abort = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(resetting, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
        try dial(resetting, to: port)
        #expect(accepted.wait(timeout: .now() + 10) == .success)
        close(resetting)
        reset.signal()

        let member = try boundClient()
        defer { close(member.fd) }
        marked.ports.withLock { _ = $0.insert(member.port) }
        try dial(member.fd, to: port)
        #expect(GatewaySocket.writeAll(member.fd, bearer(placeholder)))
        #expect(answer(member.fd).hasPrefix("HTTP/1.1 200"))
        #expect(upstream.requests.count == 1)
        // Linux sends with MSG_NOSIGNAL and has no such step: there the reset
        // connection is an outsider whose head cannot be read, refused as one.
        #if canImport(Darwin)
        #expect(audit.items.withLock { $0.allSatisfy { $0.refusal == nil } })
        #endif
    }

    /// Malformed heads from outside every runtime, one after another: the
    /// first is recorded and the rest only counted until the interval has
    /// passed; the next record says how many were left out.
    @Test(.timeLimit(.minutes(1)))
    func outsidersNamelessRefusalsAreRecordedOncePerInterval() throws {
        let nobody = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, _) = try gateway(nobody.check, upstream: upstream, audit: audit)
        gateway.outsiderAudit.interval = 60
        let port = try gateway.start().get()
        defer { gateway.stop() }
        func sendGarbage() throws -> String {
            let client = try boundClient()
            defer { close(client.fd) }
            try dial(client.fd, to: port)
            #expect(GatewaySocket.writeAll(client.fd, Array("not http\r\n\r\n".utf8)))
            return answer(client.fd)
        }
        for _ in 0..<10 { #expect(try sendGarbage().hasPrefix("HTTP/1.1 4")) }
        let malformed = { audit.items.withLock { $0.filter { $0.refusal?.code == "malformed" } } }
        #expect(malformed().count == 1)
        gateway.outsiderAudit.interval = 0
        _ = try sendGarbage()
        #expect(malformed().count == 2)
        let reason = malformed().last?.reason ?? ""
        #expect(reason.contains("(9 more from outside the runtimes since the last record)"), "\(reason)")
        #expect(upstream.requests.isEmpty)
    }

    /// Refusals left out and never followed by a record are not lost when
    /// the gateway stops: the last one is written then, with how many were
    /// left out before it.
    @Test(.timeLimit(.minutes(1)))
    func outsidersRefusalsLeftOutAreRecordedWhenTheGatewayStops() throws {
        let nobody = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, _) = try gateway(nobody.check, upstream: upstream, audit: audit)
        gateway.outsiderAudit.interval = 60
        let port = try gateway.start().get()
        defer { gateway.stop() }
        for _ in 0..<10 {
            let client = try boundClient()
            defer { close(client.fd) }
            try dial(client.fd, to: port)
            #expect(GatewaySocket.writeAll(client.fd, Array("not http\r\n\r\n".utf8)))
            #expect(answer(client.fd).hasPrefix("HTTP/1.1 4"))
        }
        let malformed = { audit.items.withLock { $0.filter { $0.refusal?.code == "malformed" } } }
        #expect(eventually { malformed().count == 1 })
        gateway.stop()
        #expect(malformed().count == 2)
        let reason = malformed().last?.reason ?? ""
        #expect(reason.contains("(8 more from outside the runtimes since the last record)"), "\(reason)")
        gateway.stop()
        #expect(malformed().count == 2)
    }

    /// Connection threads are not joined at stop, so a refusal can come
    /// after the drain: it is written then, not kept for a later stop. A
    /// gateway started again bounds afresh and never writes an earlier
    /// run's count.
    @Test(.timeLimit(.minutes(1)))
    func aRefusalAfterTheStopIsWrittenAndARestartBoundsAfresh() throws {
        let nobody = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, _) = try gateway(nobody.check, upstream: upstream, audit: audit)
        gateway.outsiderAudit.interval = 60
        func sendGarbage(_ port: Int) throws {
            let client = try boundClient()
            defer { close(client.fd) }
            try dial(client.fd, to: port)
            #expect(GatewaySocket.writeAll(client.fd, Array("not http\r\n\r\n".utf8)))
            #expect(answer(client.fd).hasPrefix("HTTP/1.1 4"))
        }
        let malformed = { audit.items.withLock { $0.filter { $0.refusal?.code == "malformed" } } }
        let first = try gateway.start().get()
        for _ in 0..<3 { try sendGarbage(first) }
        #expect(eventually { malformed().count == 1 })
        gateway.stop()
        #expect(malformed().count == 2)
        let late = try #require(malformed().last)
        #expect(gateway.outsiderAudit.admit(late) != nil, "a refusal after the drain was kept")

        let second = try gateway.start().get()
        defer { gateway.stop() }
        for _ in 0..<2 { try sendGarbage(second) }
        #expect(eventually { malformed().count == 3 })
        let reason = malformed().last?.reason ?? ""
        #expect(reason.contains("more from outside") == false, "\(reason)")
        #expect(malformed().count == 3, "the second run's refusals were not bounded")
    }

    /// Naming a secret does not lift the bound: an outsider hammering a
    /// made-up name is recorded once per interval like a nameless one. An
    /// outsider presenting a live placeholder is recorded every time, also
    /// when it is refused before any substitution (an echo method).
    @Test(.timeLimit(.minutes(1)))
    func outsidersNamingASecretAreBoundedUnlessTheyPresentALivePlaceholder() throws {
        let nobody = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(nobody.check, upstream: upstream, audit: audit)
        gateway.outsiderAudit.interval = 60
        let port = try gateway.start().get()
        defer { gateway.stop() }
        func send(_ head: String) throws -> String {
            let client = try boundClient()
            defer { close(client.fd) }
            try dial(client.fd, to: port)
            #expect(GatewaySocket.writeAll(client.fd, Array(head.utf8)))
            return answer(client.fd)
        }
        let madeUp = "GET /s/MADE_UP/models HTTP/1.1\r\nAuthorization: Bearer sk-rvph_\(String(repeating: "0", count: 32))\r\n\r\n"
        for _ in 0..<10 { #expect(try send(madeUp).hasPrefix("HTTP/1.1 4")) }
        let named = { audit.items.withLock { $0.filter { $0.secret == "MADE_UP" } } }
        #expect(named().count == 1)

        let live = String(decoding: bearer(placeholder), as: UTF8.self)
        let echo = live.replacingOccurrences(of: "GET ", with: "TRACE ")
        for _ in 0..<3 { #expect(try send(live).hasPrefix("HTTP/1.1 403")) }
        for _ in 0..<2 { #expect(try send(echo).hasPrefix("HTTP/1.1 4")) }
        let brokered = { audit.items.withLock { $0.filter { $0.secret == "OPENAI_API_KEY" } } }
        #expect(eventually { brokered().count == 5 }, "\(brokered().map { $0.refusal?.code ?? "-" })")
        #expect(named().count == 1)

        gateway.outsiderAudit.interval = 0
        _ = try send(madeUp)
        #expect(eventually { named().count == 2 })
        let reason = named().last?.reason ?? ""
        #expect(reason.contains("(9 more from outside the runtimes since the last record)"), "\(reason)")
        #expect(upstream.requests.isEmpty)
    }

    /// A live placeholder in a form the gateway itself recognises, inside
    /// `Basic` credentials or percent-encoded, counts as presented: an
    /// outsider's refusal is recorded every time, on an echo method, on an
    /// encoded placeholder and on an unknown route. The same shapes holding
    /// a made-up value stay bounded.
    @Test(.timeLimit(.minutes(1)))
    func outsidersPresentingAnEncodedLivePlaceholderAreAlwaysRecorded() throws {
        let nobody = MarkedPorts()
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(nobody.check, upstream: upstream, audit: audit)
        gateway.outsiderAudit.interval = 60
        let port = try gateway.start().get()
        defer { gateway.stop() }
        func send(_ head: String) throws -> String {
            let client = try boundClient()
            defer { close(client.fd) }
            try dial(client.fd, to: port)
            #expect(GatewaySocket.writeAll(client.fd, Array(head.utf8)))
            return answer(client.fd)
        }
        func shapes(_ text: String, secret: String) -> [String] {
            let basic = Data("user:\(text)".utf8).base64EncodedString()
            let encoded = text.replacingOccurrences(of: "rvph_", with: "rvph%5f")
            return [
                "TRACE /s/\(secret)/models HTTP/1.1\r\nAuthorization: Basic \(basic)\r\n\r\n",
                "GET /s/\(secret)/models HTTP/1.1\r\nAuthorization: Bearer \(encoded)\r\n\r\n",
                "GET /elsewhere?key=\(encoded) HTTP/1.1\r\n\r\n",
            ]
        }
        let named = { audit.items.withLock { $0.filter { $0.secret == "MADE_UP" } } }
        let brokered = { audit.items.withLock { $0.filter { $0.secret == "OPENAI_API_KEY" } } }
        let unrouted = { audit.items.withLock { $0.filter { $0.refusal?.code == "unknownRoute" } } }
        // The interval's first record, so every bounded one after it is only counted.
        #expect(try send("GET /s/MADE_UP/models HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 4"))
        #expect(named().count == 1)

        for head in shapes(placeholder.text, secret: "OPENAI_API_KEY") {
            for _ in 0..<2 { #expect(try send(head).hasPrefix("HTTP/1.1 4")) }
        }
        #expect(eventually { brokered().count == 4 }, "\(brokered().map { $0.refusal?.code ?? "-" })")
        #expect(eventually { unrouted().count == 2 })

        let madeUp = "sk-rvph_\(String(repeating: "0", count: 32))"
        for head in shapes(madeUp, secret: "MADE_UP") {
            for _ in 0..<2 { #expect(try send(head).hasPrefix("HTTP/1.1 4")) }
        }
        #expect(named().count == 1)
        #expect(unrouted().count == 2)
        #expect(upstream.requests.isEmpty)
    }

    /// A peer that could not be placed when it connected waits as an
    /// outsider, and the full check after its head decides: placed in the
    /// runtime, it is forwarded; still unplaced, it is refused.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func aPeerUnplacedAtFirstIsDecidedByTheFullCheck(placedLater: Bool) throws {
        let checked = MarkedPorts()
        let settles = GatewayPeerCheck { peer, _ in
            let first = checked.ports.withLock { $0.insert(peer.port).inserted }
            return first || placedLater == false ? .unverifiable : .member
        }
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, placeholder) = try gateway(settles, upstream: upstream, audit: audit)
        let port = try gateway.start().get()
        defer { gateway.stop() }
        let client = try boundClient()
        defer { close(client.fd) }
        try dial(client.fd, to: port)
        #expect(GatewaySocket.writeAll(client.fd, bearer(placeholder)))
        let served = answer(client.fd)
        if placedLater {
            #expect(served.hasPrefix("HTTP/1.1 200"), "\(served.prefix(80))")
            #expect(upstream.requests.count == 1)
        } else {
            #expect(served.hasPrefix("HTTP/1.1 403"), "\(served.prefix(80))")
            #expect(upstream.requests.isEmpty)
            #expect(audit.items.withLock { $0.last?.refusal?.code } == "runtimeUnverified")
        }
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
