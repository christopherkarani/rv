#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Test func egressProxyParsesStrictCONNECTOnly() {
    let valid = EgressProxy.parseCONNECT(header: "CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: x\r\n\r\n")
    #expect(valid?.host == "api.anthropic.com")
    #expect(valid?.port == 443)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT 127.0.0.1:10100 HTTP/1.0\r\n\r\n")?.port == 10100)
    #expect(EgressProxy.parseCONNECT(header: "GET http://x/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "connect api.anthropic.com:443 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT api.anthropic.com HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT :443 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT api.anthropic.com:0 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT api.anthropic.com:99999 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT api.anthropic.com:443:1 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT user@api.anthropic.com:443 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT [::1]:443 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT api.anthropic.com:443/x HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT api.anthropic.com:443 HTTP/1.1 extra\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "CONNECT  api.anthropic.com:443 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseCONNECT(header: "no-crlf-here") == nil)
}

@Test func egressProxyParsesAbsoluteHTTP() {
    let valid = EgressProxy.parseAbsoluteHTTP(header: "POST http://127.0.0.1:10100/v1/messages HTTP/1.1\r\nHost: x\r\n\r\n")
    #expect(valid?.host == "127.0.0.1")
    #expect(valid?.port == 10100)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http://localhost/ HTTP/1.0\r\n\r\n")?.port == 80)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http://api.anthropic.com/ HTTP/1.1\r\n\r\n")?.host == "api.anthropic.com")
    #expect(EgressProxy.parseAbsoluteHTTP(header: "CONNECT 127.0.0.1:10100 HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET https://127.0.0.1/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "get http://127.0.0.1/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http://user@127.0.0.1/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http://[::1]/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http:///path HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http://127.0.0.1:0/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http://127.0.0.1:1:2/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET http://127.0.0.1/ HTTP/1.1 extra\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "GET  http://127.0.0.1/ HTTP/1.1\r\n\r\n") == nil)
    #expect(EgressProxy.parseAbsoluteHTTP(header: "no-crlf-here") == nil)
}

private final class EgressDenialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var denials: [EgressProxyDenial] = []

    func record(_ denial: EgressProxyDenial) {
        lock.lock()
        denials.append(denial)
        lock.unlock()
    }

    var all: [EgressProxyDenial] {
        lock.lock()
        defer { lock.unlock() }
        return denials
    }
}

private final class EgressStubServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let reply: [UInt8]
    private let receivedLock = NSLock()
    private var receivedBytes = [UInt8]()

    var received: String {
        receivedLock.lock()
        defer { receivedLock.unlock() }
        return String(bytes: receivedBytes, encoding: .utf8) ?? ""
    }

    init?(reply: String) {
        let fd = egressStreamSocket()
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(fd, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fetched: Int32 = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getsockname(fd, address, &length)
            }
        }
        guard fetched == 0 else {
            close(fd)
            return nil
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: name.sin_port))
        self.reply = Array(reply.utf8)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptOnce() }
    }

    deinit {
        // Wake the thread parked in acceptOnce(); close() alone does not
        // interrupt a blocked accept() on Darwin.
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }

    private func acceptOnce() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return recv(fd, base, pointer.count, 0)
        }
        if count > 0 {
            receivedLock.lock()
            receivedBytes = Array(buffer[..<count])
            receivedLock.unlock()
        }
        _ = reply.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return send(fd, base, pointer.count, 0)
        }
    }
}

private func egressStreamSocket() -> Int32 {
    #if canImport(Darwin)
    return socket(AF_INET, SOCK_STREAM, 0)
    #else
    return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func egressConnect(port: Int) -> Int32? {
    let fd = egressStreamSocket()
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port)).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result: Int32 = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            connect(fd, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func egressSend(_ fd: Int32, text: String) -> Bool {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return send(fd, base.advanced(by: offset), bytes.count - offset, 0)
        }
        if written <= 0 { return false }
        offset += written
    }
    return true
}

private func egressRead(_ fd: Int32, timeoutSeconds: Int = 10) -> String {
    var collected = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&item, 1, 200)
        if ready <= 0 { continue }
        let count = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return recv(fd, base, pointer.count, 0)
        }
        if count <= 0 { break }
        collected.append(contentsOf: buffer[..<count])
        if String(bytes: collected, encoding: .utf8) != nil, collected.count >= 12 {
            // Replies are short; stop once a full status line arrived and no
            // more bytes are immediately available.
            var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&probe, 1, 200) <= 0 { break }
        }
    }
    return String(bytes: collected, encoding: .utf8) ?? ""
}

/// Read until a 403 arrives or the budget runs out. Slow CI runners can
/// delay the serve path well past one read timeout; keep polling.
private func egressReadUntil403(_ fd: Int32, tries: Int = 6) -> String {
    var response = ""
    for _ in 0..<tries {
        response += egressRead(fd)
        if response.contains("HTTP/1.1 403") { break }
    }
    return response
}

private func egressReadUntil407(_ fd: Int32, tries: Int = 6) -> String {
    var response = ""
    for _ in 0..<tries {
        response += egressRead(fd)
        if response.contains("HTTP/1.1 407") { break }
    }
    return response
}

private func egressCandidateV4(_ text: String, port: Int) -> EgressDialCandidate? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    let parsed: Int32 = text.withCString { cString in
        inet_pton(AF_INET, cString, &addr.sin_addr)
    }
    guard parsed == 1 else { return nil }
    var storage = sockaddr_storage()
    withUnsafeBytes(of: &addr) { raw in
        withUnsafeMutableBytes(of: &storage) { target in
            target.copyMemory(from: raw)
        }
    }
    #if canImport(Darwin)
    let socktype: Int32 = SOCK_STREAM
    let proto: Int32 = IPPROTO_TCP
    #else
    let socktype: Int32 = Int32(SOCK_STREAM.rawValue)
    let proto: Int32 = Int32(IPPROTO_TCP)
    #endif
    return EgressDialCandidate(
        family: AF_INET,
        socktype: socktype,
        proto: proto,
        address: storage,
        length: socklen_t(MemoryLayout<sockaddr_in>.size)
    )
}

/// Denials are recorded on the proxy's relay queue after the reply is
/// written; wait for the callback to land instead of asserting immediately.
private func egressAwaitDenials(_ collector: EgressDenialCollector, count: Int, tries: Int = 100) {
    for _ in 0..<tries {
        if collector.all.count >= count { break }
        usleep(100_000)
    }
}

@Test func egressProxyRefusesLoopbackWhenTheCageCannotDialIt() throws {
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        policy: EgressHostPolicy(allowedHosts: ["api.example.com"], relaysLoopback: false), record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.first?.reason == .deniedPolicy)
    #expect(collector.all.first?.host == "127.0.0.1")
}

@Test func credentialedProxyIsNotAnOpenRelay() throws {
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        policy: EgressHostPolicy(allowedHosts: ["api.example.com"], relaysLoopback: false),
        record: { collector.record($0) }, clientCredential: "secret-token")
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let anonymous = try #require(egressConnect(port: port))
    defer { close(anonymous) }
    #expect(egressSend(anonymous, text: "CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n"))
    #expect(egressReadUntil403(anonymous).contains("HTTP/1.1 407"))

    let encoded = Data("secret-token:x".utf8).base64EncodedString()
    let authed = try #require(egressConnect(port: port))
    defer { close(authed) }
    #expect(egressSend(
        authed,
        text: "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\nProxy-Authorization: Basic \(encoded)\r\n\r\n"))
    #expect(egressReadUntil403(authed).contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 2)
    #expect(collector.all.map(\.reason) == [.deniedCredential, .deniedPolicy])
}

@Test func egressProxyRelaysLoopbackTargets() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    #expect(proxy.start() == .success(port))
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
    #expect(egressSend(client, text: "PING\n"))
    var response = ""
    for _ in 0..<10 {
        response += egressRead(client)
        if response.contains("PONG") { break }
    }
    #expect(response.contains("HTTP/1.1 200"))
    #expect(response.contains("PONG"))
    #expect(collector.all.isEmpty)
}

@Test func egressDial_reportsFilterRefusalAndConnectOutcomes() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    // Numeric loopback resolves without DNS; the external filter rejects it.
    #expect(
        EgressProxy.dial(host: "127.0.0.1", port: stub.port, external: true)
            == .addressFiltered
    )
    // Loopback targets bypass the filter and connect.
    switch EgressProxy.dial(host: "127.0.0.1", port: stub.port, external: false) {
    case .connected(let fd):
        close(fd)
    case .dnsFailed, .addressFiltered, .connectFailed:
        Issue.record("loopback dial to a live stub must connect")
    }
    // Nothing listens on discard; refusal is connectFailed, not dnsFailed.
    #expect(
        EgressProxy.dial(host: "127.0.0.1", port: 9, external: false) == .connectFailed
    )
    // .invalid never resolves.
    #expect(
        EgressProxy.dial(host: "no-such-host.invalid", port: 443, external: true) == .dnsFailed
    )
}

@Test func egressProxyRelaysLoopbackAbsoluteHTTP() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "POST http://127.0.0.1:\(stub.port)/v1/x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"))
    var response = ""
    for _ in 0..<10 {
        response += egressRead(client)
        if response.contains("PONG") { break }
    }
    #expect(response.contains("PONG"))
    #expect(collector.all.isEmpty)
    for _ in 0..<50 {
        if stub.received.contains("POST http://127.0.0.1:") { break }
        usleep(100_000)
    }
    #expect(stub.received.contains("POST http://127.0.0.1:"))
    #expect(stub.received.contains("/v1/x"))
}

@Test func egressProxyDeniesExternalAbsoluteHTTP() throws {
    // Legacy narrow mode: the Standard default (publicHTTPS) admits public
    // port-80 traffic, so pin the allowlist policy for this denial shape.
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(policy: .agentAPIs, record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "GET http://denied.example/ HTTP/1.1\r\n\r\n"))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.host == "denied.example")
    #expect(collector.all.first?.port == 80)
    #expect(collector.all.first?.reason == .deniedPolicy)
}

@Test func egressProxyDeniesUnknownHosts() throws {
    // Legacy narrow mode: the Standard default (publicHTTPS) admits any
    // valid public DNS name, so pin the allowlist policy here.
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(policy: .agentAPIs, record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT denied.example:443 HTTP/1.1\r\n\r\n"))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.host == "denied.example")
    #expect(collector.all.first?.port == 443)
    #expect(collector.all.first?.reason == .deniedPolicy)
}

@Test func egressProxyDeniesMalformedAndBypassShapes() throws {
    // Legacy narrow mode (see above): port-80 and non-allowlist shapes are
    // denied here; publicHTTPS admits them subject to the dial filter.
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(policy: .agentAPIs, record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    for request in [
        "GET http://api.anthropic.com/ HTTP/1.1\r\n\r\n",
        "CONNECT 1.2.3.4:443 HTTP/1.1\r\n\r\n",
        "CONNECT user@api.anthropic.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT api.anthropic.com:80 HTTP/1.1\r\n\r\n",
    ] {
        let client = try #require(egressConnect(port: port))
        #expect(egressSend(client, text: request))
        let response = egressReadUntil403(client)
        close(client)
        #expect(response.contains("HTTP/1.1 403"))
    }
    egressAwaitDenials(collector, count: 4)
    #expect(collector.all.count == 4)
    let reasons = Set(collector.all.map(\.reason))
    #expect(reasons.contains(.malformed))
    #expect(reasons.contains(.deniedPolicy))
}

@Test func egressProxyReportsDialFailures() throws {
    // A port nothing listens on: admitted by the loopback rule, then refused.
    let reserved = egressStreamSocket()
    try #require(reserved >= 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound: Int32 = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            bind(reserved, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    var name = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let fetched: Int32 = withUnsafeMutablePointer(to: &name) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            getsockname(reserved, address, &length)
        }
    }
    try #require(fetched == 0)
    let closedPort = Int(UInt16(bigEndian: name.sin_port))
    close(reserved)
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:\(closedPort) HTTP/1.1\r\n\r\n"))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.reason == .dialFailed)
}

@Test func egressProxyRecordsDnsFailuresPrecisely() throws {
    // Admitted by the public-HTTPS policy (valid syntax), then NXDOMAIN:
    // records dns-failed, not the old catch-all dial-failed.
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(policy: .publicHTTPS, record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(
        egressSend(client, text: "CONNECT no-such-host.invalid:443 HTTP/1.1\r\n\r\n")
    )
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.host == "no-such-host.invalid")
    #expect(collector.all.first?.reason == .dnsFailed)
}

@Test func egressProxyRejectsOversizeHeaders() throws {
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: String(repeating: "A", count: 70_000)))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.first?.reason == .headerTooLarge)
}

private final class AuditDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

@Test func egressDenialAppendPersistsAndSurfacesFailure() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-egress-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let denial = EgressProxyDenial(
        host: "denied.example", port: 443, reason: .deniedPolicy,
        recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let diagnostics = AuditDiagnosticCollector()
    let url = directory.appendingPathComponent("egress-denials.jsonl")
    #expect(EgressProxy.writeDenial(denial, to: url, diagnose: diagnostics.record))
    #expect(diagnostics.all.isEmpty)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("denied.example"))
    #expect(text.contains("denied-policy"))

    // Fault injection: the log parent is a regular file, so neither the
    // append nor the fallback create can persist. The failure must surface
    // as a diagnostic instead of vanishing through `try?`.
    let blocker = directory.appendingPathComponent("blocker")
    try Data("file".utf8).write(to: blocker)
    let badURL = blocker.appendingPathComponent("egress-denials.jsonl")
    #expect(EgressProxy.writeDenial(denial, to: badURL, diagnose: diagnostics.record) == false)
    #expect(diagnostics.all.isEmpty == false)
}

@Test func egressDenialReasonsPinLogSpellings() {
    // `egress-denials.jsonl` readers (including out-of-repo ones) match on
    // these spellings, so adding a reason is a log-format change. The full
    // set is pinned here: `dial-failed` narrowed to connect-only failures,
    // while DNS and filter refusals record as the newer `dns-failed` and
    // `address-filtered` values. Binary scope adds `binary-mismatch`
    // (bound binary not admitted or TOFU pin broken) and
    // `unattributed-peer` (binary-scoped policy on an unbound instance),
    // credentialed-mode auth failures record as `denied-credential`, and
    // a credentialed tunnel whose ClientHello SNI is not the CONNECT
    // authority records as `sni-mismatch`.
    #expect(
        EgressDenialReason.allCases.map(\.rawValue).sorted() == [
            "address-filtered",
            "binary-mismatch",
            "denied-credential",
            "denied-policy",
            "dial-failed",
            "dns-failed",
            "header-too-large",
            "malformed",
            "sni-mismatch",
            "unattributed-peer",
        ]
    )
}

private func egressIsPublicUnicast(family: Int32, _ text: String) -> Bool? {
    var storage = sockaddr_storage()
    let parsed: Int32 = text.withCString { cString in
        withUnsafeMutablePointer(to: &storage) { pointer in
            if family == AF_INET {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                    addr.pointee.sin_family = sa_family_t(AF_INET)
                    return inet_pton(AF_INET, cString, &addr.pointee.sin_addr)
                }
            } else {
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addr in
                    addr.pointee.sin6_family = sa_family_t(AF_INET6)
                    return inet_pton(AF_INET6, cString, &addr.pointee.sin6_addr)
                }
            }
        }
    }
    guard parsed == 1 else { return nil }
    return withUnsafePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, EgressProxy.isPublicUnicast)
    }
}

@Test func egressProxyExternalDialFilterRejectsNonPublicAddresses() throws {
    let publicV4 = ["8.8.8.8", "1.1.1.1", "142.250.72.14", "11.0.0.1", "172.15.0.1", "172.32.0.1", "100.128.0.1", "198.20.0.1"]
    for text in publicV4 {
        #expect(try #require(egressIsPublicUnicast(family: AF_INET, text)))
    }
    // Loopback, private, CGNAT, link-local (covers 169.254.169.254),
    // multicast, reserved, documentation, benchmarking, unspecified.
    let deniedV4 = [
        "127.0.0.1", "127.1.2.3", "10.0.0.1", "172.16.5.4", "172.31.255.255",
        "192.168.1.1", "100.64.0.1", "100.127.255.255", "169.254.169.254",
        "224.0.0.1", "255.255.255.255", "0.0.0.0", "192.0.2.1",
        "198.51.100.2", "203.0.113.3", "198.18.0.1", "198.19.1.1",
    ]
    for text in deniedV4 {
        #expect(try #require(egressIsPublicUnicast(family: AF_INET, text)) == false)
    }

    let publicV6 = ["2606:4700:4700::1111", "2001:4860:4860::8888"]
    for text in publicV6 {
        #expect(try #require(egressIsPublicUnicast(family: AF_INET6, text)))
    }
    let deniedV6 = [
        "::1", "::", "fe80::1", "febf::1", "fec0::1", "fc00::1", "fd00::1",
        "ff02::1", "2001:db8::1",
    ]
    for text in deniedV6 {
        #expect(try #require(egressIsPublicUnicast(family: AF_INET6, text)) == false)
    }
    // Embedded-IPv4 forms recurse into the v4 verdict.
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "::ffff:8.8.8.8")))
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "::ffff:10.0.0.1")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "::ffff:127.0.0.1")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "::8.8.8.8")))
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "::10.0.0.1")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "2002:808:808::1")))
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "2002:a00:1::1")) == false)
    // NAT64 embeddings recurse into the v4 verdict; special ranges deny.
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "64:ff9b::808:808")))
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "64:ff9b::a9fe:a9fe")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "64:ff9b::7f00:1")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "64:ff9b:1:808:808::")))
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "64:ff9b:1:a00:1::")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "64:ff9b:1::808:808")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "2001::1")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "2001:20::1")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "2001:2::1")) == false)
    #expect(try #require(egressIsPublicUnicast(family: AF_INET6, "100::1")) == false)

    #expect(EgressProxy.isPublicUnicast(nil) == false)
    var zero = sockaddr_storage()
    let unknownFamily = withUnsafePointer(to: &zero) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, EgressProxy.isPublicUnicast)
    }
    #expect(unknownFamily == false)
}

@Test func egressProxyParsesClientHelloSNIAndRejectsMalformed() {
    func hello(_ host: String?) -> [UInt8] {
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 32) + [0x00]
        body += [0x00, 0x02, 0x13, 0x01, 0x01, 0x00]
        var extensions: [UInt8] = []
        if let host {
            let name = Array(host.utf8)
            let entry: [UInt8] = [0x00, UInt8(name.count >> 8), UInt8(name.count & 0xFF)] + name
            let sni: [UInt8] = [UInt8(entry.count >> 8), UInt8(entry.count & 0xFF)] + entry
            extensions += [0x00, 0x00, UInt8(sni.count >> 8), UInt8(sni.count & 0xFF)] + sni
        }
        body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xFF)] + extensions
        var record: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x00, 0x01,
                               UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
        let length = record.count - 5
        record[3] = UInt8(length >> 8)
        record[4] = UInt8(length & 0xFF)
        return record
    }
    #expect(EgressProxy.tlsServerName(hello("api.example.com")) == "api.example.com")
    #expect(EgressProxy.tlsServerName(hello(nil)) == nil)
    #expect(EgressProxy.tlsServerName([]) == nil)
    #expect(EgressProxy.tlsServerName([0x16, 0x03, 0x01]) == nil)
    #expect(EgressProxy.tlsServerName(Array(hello("api.example.com").prefix(20))) == nil)
    var truncated = hello("api.example.com")
    truncated[3] = 0xFF
    #expect(EgressProxy.tlsServerName(truncated) == nil)
    var notTLS = hello("api.example.com")
    notTLS[0] = 0x17
    #expect(EgressProxy.tlsServerName(notTLS) == nil)
    var huge = hello("api.example.com")
    huge[5 + 4 + 2 + 32] = 0xFF // session id length runs past the record
    #expect(EgressProxy.tlsServerName(huge) == nil)
}

/// Scripted `stat`/hash backend for binary-gate tests: no filesystem,
/// deterministic TOFU transitions driven by the test.
private final class EgressPinScript: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: EgressBinaryFingerprint?
    private var digest: String?
    private(set) var hashCalls = 0

    init(fingerprint: EgressBinaryFingerprint?, digest: String?) {
        self.fingerprint = fingerprint
        self.digest = digest
    }

    func retarget(fingerprint: EgressBinaryFingerprint?, digest: String?) {
        lock.lock()
        self.fingerprint = fingerprint
        self.digest = digest
        lock.unlock()
    }

    func capture(_ path: String) -> EgressBinaryFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        return fingerprint
    }

    func hash(_ path: String) -> String? {
        lock.lock()
        hashCalls += 1
        let digest = digest
        lock.unlock()
        return digest
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return hashCalls
    }
}

private func egressFingerprint(size: UInt64 = 128, inode: UInt64 = 7) -> EgressBinaryFingerprint {
    EgressBinaryFingerprint(
        size: size,
        mtimeSeconds: 1_700_000_000,
        mtimeNanoseconds: 0,
        ctimeSeconds: 1_700_000_000,
        ctimeNanoseconds: 0,
        device: 1,
        inode: inode
    )
}

private func egressScopedCache(
    _ script: EgressPinScript,
    path: String = "/opt/rv/bin/agent"
) -> (EgressBinaryPolicy, EgressRuntimeAttribution, EgressBinaryPinCache) {
    let policy = EgressBinaryPolicy(canonicalPaths: [path])
    let attribution = EgressRuntimeAttribution(binaryPath: path)
    let pins = EgressBinaryPinCache(
        fingerprint: { script.capture($0) },
        hashFile: { script.hash($0) }
    )
    return (policy, attribution, pins)
}

@Test func egressProxyRelaysWhenBinaryScopeMatches() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let script = EgressPinScript(fingerprint: egressFingerprint(), digest: "golden")
    let (binaryPolicy, attribution, pins) = egressScopedCache(script)
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        binaryPolicy: binaryPolicy,
        attribution: attribution,
        pins: pins,
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
    #expect(egressSend(client, text: "PING\n"))
    var response = ""
    for _ in 0..<10 {
        response += egressRead(client)
        if response.contains("PONG") { break }
    }
    #expect(response.contains("HTTP/1.1 200"))
    #expect(response.contains("PONG"))
    #expect(collector.all.isEmpty)
    #expect(script.calls == 1)
}

@Test func egressProxyDeniesUnattributedPeerUnderBinaryScope() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\n\r\n"))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.reason == .unattributedPeer)
    #expect(collector.all.first?.binaryPath == nil)
    #expect(collector.all.first?.host == "127.0.0.1")
}

@Test func egressProxyDeniesBinaryMismatch() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let script = EgressPinScript(fingerprint: egressFingerprint(), digest: "golden")
    let pins = EgressBinaryPinCache(
        fingerprint: { script.capture($0) },
        hashFile: { script.hash($0) }
    )
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        attribution: EgressRuntimeAttribution(binaryPath: "/opt/rv/bin/other"),
        pins: pins,
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\n\r\n"))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.reason == .binaryMismatch)
    #expect(collector.all.first?.binaryPath == "/opt/rv/bin/other")
    // Policy mismatch denies before any `stat`/hash: nothing to pin.
    #expect(script.calls == 0)
}

@Test func egressProxyDeniesPinMismatchMidRuntime() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let script = EgressPinScript(fingerprint: egressFingerprint(), digest: "golden")
    let (binaryPolicy, attribution, pins) = egressScopedCache(script)
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        binaryPolicy: binaryPolicy,
        attribution: attribution,
        pins: pins,
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let first = try #require(egressConnect(port: port))
    #expect(egressSend(first, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\n\r\n"))
    #expect(egressSend(first, text: "PING\n"))
    var relayed = ""
    for _ in 0..<10 {
        relayed += egressRead(first)
        if relayed.contains("PONG") { break }
    }
    close(first)
    #expect(relayed.contains("HTTP/1.1 200"))
    // Binary swapped mid-runtime: new fingerprint, new hash.
    script.retarget(fingerprint: egressFingerprint(inode: 9), digest: "tampered")
    let second = try #require(egressConnect(port: port))
    defer { close(second) }
    #expect(egressSend(second, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\n\r\n"))
    let response = egressReadUntil403(second)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.reason == .binaryMismatch)
    #expect(collector.all.first?.binaryPath == "/opt/rv/bin/agent")
}

@Test func egressProxyBinaryGateAppliesToAbsoluteHTTP() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "POST http://127.0.0.1:\(stub.port)/v1/x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"))
    let response = egressReadUntil403(client)
    #expect(response.contains("HTTP/1.1 403"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.first?.reason == .unattributedPeer)
}

@Test func egressProxyIgnoresAttributionWithoutBinaryScope() throws {
    // Host-level rules only: bound or not, the endpoint policy decides
    // exactly as before (the legacy shared instance keeps working).
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(
        attribution: EgressRuntimeAttribution(binaryPath: "/opt/rv/bin/agent"),
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
    #expect(egressSend(client, text: "PING\n"))
    var response = ""
    for _ in 0..<10 {
        response += egressRead(client)
        if response.contains("PONG") { break }
    }
    #expect(response.contains("HTTP/1.1 200"))
    #expect(response.contains("PONG"))
    #expect(collector.all.isEmpty)
}

@Test func egressProxyCredentialMintsUniqueTokens() {
    let first = EgressProxyCredential()
    let second = EgressProxyCredential()
    #expect(first.rawValue.count == 64)
    #expect(first.rawValue.allSatisfy { $0.isHexDigit })
    #expect(first != second)
    #expect(first == EgressProxyCredential(rawValue: first.rawValue))
    #expect(first == first)
    #expect(EgressProxyCredential(rawValue: "short") != first)
}

@Test func egressProxyParsesProxyAuthorization() {
    let header = { (fields: String) in "CONNECT example.com:443 HTTP/1.1\r\n\(fields)\r\n" }
    #expect(
        EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Bearer abc123"))
            == "abc123"
    )
    #expect(
        EgressProxy.proxyCredentialToken(header: header("proxy-authorization: bearer abc123"))
            == "abc123"
    )
    #expect(
        EgressProxy.proxyCredentialToken(header: header("PROXY-AUTHORIZATION:   Bearer abc123  "))
            == "abc123"
    )
    // Stock clients send `*_PROXY` URL userinfo as Basic: the username
    // carries the token.
    let basic = Data("tok-1:".utf8).base64EncodedString()
    #expect(
        EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Basic \(basic)"))
            == "tok-1"
    )
    let basicPassword = Data("tok-1:ignored".utf8).base64EncodedString()
    #expect(
        EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Basic \(basicPassword)"))
            == "tok-1"
    )
    #expect(EgressProxy.proxyCredentialToken(header: header("")) == nil)
    #expect(EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization:")) == nil)
    #expect(EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Bearer")) == nil)
    #expect(
        EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Bearer a b")) == nil
    )
    #expect(
        EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Digest xyz")) == nil
    )
    #expect(
        EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Basic !!!")) == nil
    )
    let noColon = Data("tok-1".utf8).base64EncodedString()
    #expect(
        EgressProxy.proxyCredentialToken(header: header("Proxy-Authorization: Basic \(noColon)"))
            == nil
    )
}

@Test func egressProxyCredentialedModeRelaysWithBearer() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let credential = EgressProxyCredential()
    let proxy = EgressProxy(
        grants: [credential: EgressGrant(principal: EgressPrincipal(rawValue: "runtime-a"), policy: .publicHTTPS)],
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(
        egressSend(
            client,
            text:
                "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n"
        )
    )
    #expect(egressSend(client, text: "PING\n"))
    var response = ""
    for _ in 0..<10 {
        response += egressRead(client)
        if response.contains("PONG") { break }
    }
    #expect(response.contains("HTTP/1.1 200"))
    #expect(response.contains("PONG"))
    #expect(collector.all.isEmpty)
}

@Test func egressProxyCredentialedModeDeniesUnauthenticated() throws {
    let collector = EgressDenialCollector()
    let credential = EgressProxyCredential()
    let proxy = EgressProxy(
        grants: [credential: EgressGrant(principal: EgressPrincipal(rawValue: "runtime-a"), policy: .publicHTTPS)],
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    for request in [
        "CONNECT denied.example:443 HTTP/1.1\r\n\r\n",
        "CONNECT denied.example:443 HTTP/1.1\r\nProxy-Authorization: Bearer wrong-token\r\n\r\n",
        "CONNECT denied.example:443 HTTP/1.1\r\nProxy-Authorization: Bearer\r\n\r\n",
    ] {
        let client = try #require(egressConnect(port: port))
        #expect(egressSend(client, text: request))
        let response = egressReadUntil407(client)
        close(client)
        #expect(response.contains("HTTP/1.1 407"))
    }
    egressAwaitDenials(collector, count: 3)
    #expect(collector.all.count == 3)
    #expect(collector.all.allSatisfy { $0.reason == .deniedCredential })
    #expect(collector.all.allSatisfy { $0.host == "denied.example" && $0.port == 443 })
}

@Test func egressProxyCredentialedModeBindsSiblingGrants() throws {
    // One instance, two sibling credentials, different rights: the narrow
    // sibling cannot ride the wide sibling's grant.
    let collector = EgressDenialCollector()
    let wide = EgressProxyCredential()
    let narrow = EgressProxyCredential()
    let proxy = EgressProxy(
        grants: [
            wide: EgressGrant(principal: EgressPrincipal(rawValue: "runtime-a"), policy: .publicHTTPS),
            narrow: EgressGrant(
                principal: EgressPrincipal(rawValue: "runtime-b"),
                policy: EgressHostPolicy(allowedHosts: ["api.anthropic.com"])
            ),
        ],
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    // Narrow sibling asks for a name outside its allowlist: judged against
    // its own grant (policy deny), not the wide sibling's.
    let denied = try #require(egressConnect(port: port))
    #expect(
        egressSend(
            denied,
            text:
                "CONNECT no-such-host.invalid:443 HTTP/1.1\r\nProxy-Authorization: Bearer \(narrow.rawValue)\r\n\r\n"
        )
    )
    #expect(egressReadUntil403(denied).contains("HTTP/1.1 403"))
    close(denied)
    // Wide sibling asks for the same name: admitted by policy (valid public
    // name), then refused at dial because `.invalid` never resolves.
    let admitted = try #require(egressConnect(port: port))
    #expect(
        egressSend(
            admitted,
            text:
                "CONNECT no-such-host.invalid:443 HTTP/1.1\r\nProxy-Authorization: Bearer \(wide.rawValue)\r\n\r\n"
        )
    )
    #expect(egressReadUntil403(admitted).contains("HTTP/1.1 403"))
    close(admitted)
    egressAwaitDenials(collector, count: 2)
    #expect(collector.all.count == 2)
    let reasons = Set(collector.all.map(\.reason))
    #expect(reasons == [.deniedPolicy, .dnsFailed])
}

@Test func egressProxyCredentialedModeRequiresAuthOnAbsoluteHTTP() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let credential = EgressProxyCredential()
    let proxy = EgressProxy(
        grants: [credential: EgressGrant(principal: EgressPrincipal(rawValue: "runtime-a"), policy: .publicHTTPS)],
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let denied = try #require(egressConnect(port: port))
    #expect(egressSend(denied, text: "POST http://127.0.0.1:\(stub.port)/v1/x HTTP/1.1\r\n\r\n"))
    #expect(egressReadUntil407(denied).contains("HTTP/1.1 407"))
    close(denied)
    // Basic userinfo form relays, like Bearer.
    let basic = Data("\(credential.rawValue):".utf8).base64EncodedString()
    let allowed = try #require(egressConnect(port: port))
    defer { close(allowed) }
    #expect(
        egressSend(
            allowed,
            text:
                "POST http://127.0.0.1:\(stub.port)/v1/x HTTP/1.1\r\nProxy-Authorization: Basic \(basic)\r\nContent-Length: 0\r\n\r\n"
        )
    )
    var response = ""
    for _ in 0..<10 {
        response += egressRead(allowed)
        if response.contains("PONG") { break }
    }
    #expect(response.contains("PONG"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.reason == .deniedCredential)
}

@Test func egressProxyCredentialedEmptyGrantsDenyAll() throws {
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(grants: [:], record: { collector.record($0) })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(
        egressSend(
            client,
            text:
                "CONNECT 127.0.0.1:80 HTTP/1.1\r\nProxy-Authorization: Bearer \(EgressProxyCredential().rawValue)\r\n\r\n"
        )
    )
    #expect(egressReadUntil407(client).contains("HTTP/1.1 407"))
    egressAwaitDenials(collector, count: 1)
    #expect(collector.all.first?.reason == .deniedCredential)
}

@Test func egressDialRefusesMixedAnswerSetsWithoutDialing() throws {
    let loopback = try #require(egressCandidateV4("127.0.0.1", port: 9))
    let linkLocal = try #require(egressCandidateV4("169.254.169.254", port: 443))
    let publicCandidate = try #require(egressCandidateV4("8.8.8.8", port: 443))
    // Mixed public + non-public: refused without dialing either.
    #expect(
        EgressProxy.dial(
            host: "mixed.example", port: 443, external: true,
            resolve: { _, _ in [publicCandidate, linkLocal] }
        ) == .addressFiltered
    )
    #expect(
        EgressProxy.dial(
            host: "mixed.example", port: 443, external: true,
            resolve: { _, _ in [linkLocal, publicCandidate] }
        ) == .addressFiltered
    )
    // All non-public: filtered, as before.
    #expect(
        EgressProxy.dial(
            host: "loopback.example", port: 9, external: true,
            resolve: { _, _ in [loopback] }
        ) == .addressFiltered
    )
    // Empty resolution: DNS failure, as before.
    #expect(
        EgressProxy.dial(host: "empty.example", port: 443, external: true, resolve: { _, _ in [] })
            == .dnsFailed
    )
    // Same loopback candidate with the loopback bypass still dials (and is
    // refused by the closed port): the injected candidates reach the dial
    // loop, so the verdict above gates rather than shadows it.
    #expect(
        EgressProxy.dial(
            host: "127.0.0.1", port: 9, external: false, resolve: { _, _ in [loopback] }
        ) == .connectFailed
    )
    // A loopback name resolving to a non-loopback candidate is filtered:
    // the bypass verifies candidates, it does not trust the resolver.
    #expect(
        EgressProxy.dial(
            host: "localhost", port: 443, external: false,
            resolve: { _, _ in [publicCandidate] }
        ) == .addressFiltered
    )
}

@Test func egressDialAttemptsPurePublicAnswerSets() throws {
    // A purely public answer set proceeds to dial: either the connection
    // succeeds or the refusal records as a connect failure, never as a
    // filter or DNS refusal.
    let publicCandidate = try #require(egressCandidateV4("8.8.8.8", port: 443))
    switch EgressProxy.dial(
        host: "dns.example", port: 443, external: true, resolve: { _, _ in [publicCandidate] }
    ) {
    case .connected(let fd):
        close(fd)
    case .connectFailed:
        break
    case .dnsFailed, .addressFiltered:
        Issue.record("pure-public answer set must be attempted, not filtered")
    }
}

@Test func egressProxyStripsProxyAuthorizationOnAbsoluteHTTPForward() throws {
    // LEAK-1 (2026-10-10): Proxy-Authorization is hop-by-hop (RFC 7235).
    // The proxy consumes it for grant lookup and must never forward it
    // upstream, where a loopback gateway could harvest and replay it.
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let credential = EgressProxyCredential()
    let proxy = EgressProxy(
        grants: [credential: EgressGrant(principal: EgressPrincipal(rawValue: "runtime-a"), policy: .publicHTTPS)],
        record: { collector.record($0) }
    )
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(
        egressSend(
            client,
            text:
                "POST http://127.0.0.1:\(stub.port)/v1/x HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\nContent-Length: 0\r\n\r\n"
        )
    )
    var response = ""
    for _ in 0..<10 {
        response += egressRead(client)
        if response.contains("PONG") { break }
    }
    #expect(response.contains("PONG"))
    for _ in 0..<50 {
        if stub.received.contains("POST http://127.0.0.1:") { break }
        usleep(100_000)
    }
    #expect(stub.received.contains("POST http://127.0.0.1:"))
    #expect(stub.received.contains("Proxy-Authorization") == false)
    #expect(stub.received.contains(credential.rawValue) == false)
    #expect(collector.all.isEmpty)
}

@Test func egressProxyStripProxyAuthorizationUnitShapes() {
    // Absent: byte-identical round-trip, framing preserved.
    let plain = "POST http://127.0.0.1:9/x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
    #expect(EgressProxy.stripProxyAuthorization(header: plain) == plain)
    // Present, mixed case + surrounding spaces: dropped, rest intact.
    let mixed =
        "POST http://127.0.0.1:9/x HTTP/1.1\r\nHost: 127.0.0.1\r\n  pRoXy-AuThOrIzAtIoN : Bearer abc123 \r\nContent-Length: 0\r\n\r\n"
    #expect(
        EgressProxy.stripProxyAuthorization(header: mixed)
            == "POST http://127.0.0.1:9/x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
    )
    // Multiple fields and obs-fold continuations: all dropped.
    let folded =
        "GET http://127.0.0.1:9/ HTTP/1.1\r\nProxy-Authorization: Bearer one\r\n Proxy-Authorization: Bearer two\r\n\tBearer three\r\nHost: h\r\n\r\n"
    #expect(
        EgressProxy.stripProxyAuthorization(header: folded)
            == "GET http://127.0.0.1:9/ HTTP/1.1\r\nHost: h\r\n\r\n"
    )
    // Similarly-named fields are not proxy credentials: kept.
    let similar =
        "GET http://127.0.0.1:9/ HTTP/1.1\r\nX-Proxy-Authorization: keep\r\nProxy-Authorization-Extra: keep\r\nProxy-Authenticate: keep\r\n\r\n"
    #expect(EgressProxy.stripProxyAuthorization(header: similar) == similar)
    // Colon-less malformed lines starting with the field name: dropped.
    let malformed =
        "GET http://127.0.0.1:9/ HTTP/1.1\r\nProxy-Authorization Bearer abc123\r\nHost: h\r\n\r\n"
    #expect(
        EgressProxy.stripProxyAuthorization(header: malformed)
            == "GET http://127.0.0.1:9/ HTTP/1.1\r\nHost: h\r\n\r\n"
    )
}
