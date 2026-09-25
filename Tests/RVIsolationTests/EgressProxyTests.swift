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
        let fd = socket(AF_INET, SOCK_STREAM, 0)
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
        DispatchQueue.global().async { [weak self] in self?.acceptOnce() }
    }

    deinit {
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

private func egressConnect(port: Int) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
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

@Test func egressProxyRelaysLoopbackTargets() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try #require(proxy.start())
    defer { proxy.stop() }
    #expect(proxy.start() == port)
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

@Test func egressProxyRelaysLoopbackAbsoluteHTTP() throws {
    let stub = try #require(EgressStubServer(reply: "PONG\n"))
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try #require(proxy.start())
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
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try #require(proxy.start())
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "GET http://denied.example/ HTTP/1.1\r\n\r\n"))
    let response = egressRead(client)
    #expect(response.contains("HTTP/1.1 403"))
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.host == "denied.example")
    #expect(collector.all.first?.port == 80)
    #expect(collector.all.first?.reason == "denied-policy")
}

@Test func egressProxyDeniesUnknownHosts() throws {
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try #require(proxy.start())
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT denied.example:443 HTTP/1.1\r\n\r\n"))
    let response = egressRead(client)
    #expect(response.contains("HTTP/1.1 403"))
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.host == "denied.example")
    #expect(collector.all.first?.port == 443)
    #expect(collector.all.first?.reason == "denied-policy")
}

@Test func egressProxyDeniesMalformedAndBypassShapes() throws {
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try #require(proxy.start())
    defer { proxy.stop() }
    for request in [
        "GET http://api.anthropic.com/ HTTP/1.1\r\n\r\n",
        "CONNECT 1.2.3.4:443 HTTP/1.1\r\n\r\n",
        "CONNECT user@api.anthropic.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT api.anthropic.com:80 HTTP/1.1\r\n\r\n",
    ] {
        let client = try #require(egressConnect(port: port))
        #expect(egressSend(client, text: request))
        let response = egressRead(client)
        close(client)
        #expect(response.contains("HTTP/1.1 403"))
    }
    #expect(collector.all.count == 4)
    let reasons = Set(collector.all.map(\.reason))
    #expect(reasons.contains("malformed"))
    #expect(reasons.contains("denied-policy"))
}

@Test func egressProxyReportsDialFailures() throws {
    // A port nothing listens on: admitted by the loopback rule, then refused.
    let reserved = socket(AF_INET, SOCK_STREAM, 0)
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
    let port = try #require(proxy.start())
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: "CONNECT 127.0.0.1:\(closedPort) HTTP/1.1\r\n\r\n"))
    let response = egressRead(client)
    #expect(response.contains("HTTP/1.1 403"))
    #expect(collector.all.count == 1)
    #expect(collector.all.first?.reason == "dial-failed")
}

@Test func egressProxyRejectsOversizeHeaders() throws {
    let collector = EgressDenialCollector()
    let proxy = EgressProxy(record: { collector.record($0) })
    let port = try #require(proxy.start())
    defer { proxy.stop() }
    let client = try #require(egressConnect(port: port))
    defer { close(client) }
    #expect(egressSend(client, text: String(repeating: "A", count: 70_000)))
    let response = egressRead(client)
    #expect(response.contains("HTTP/1.1 403"))
    #expect(collector.all.first?.reason == "header-too-large")
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

    #expect(EgressProxy.isPublicUnicast(nil) == false)
    var zero = sockaddr_storage()
    let unknownFamily = withUnsafePointer(to: &zero) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, EgressProxy.isPublicUnicast)
    }
    #expect(unknownFamily == false)
}
