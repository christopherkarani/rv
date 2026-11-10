#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Destination-address checks after the proxy resolves a CONNECT host: the
/// pure classifier, the bounded resolver, and the proxy wiring that dials
/// exactly the address set it checked.
@Suite struct EgressDestinationCheckTests {
    struct AddressCase: Sendable, CustomTestStringConvertible {
        var text: String
        var isPublic: Bool
        var testDescription: String { "\(text) -> \(isPublic ? "public" : "denied")" }
    }

    static let ipv4Cases: [AddressCase] = [
        // Public unicast, including the edges just outside denied ranges.
        .init(text: "8.8.8.8", isPublic: true),
        .init(text: "1.1.1.1", isPublic: true),
        .init(text: "9.255.255.255", isPublic: true),
        .init(text: "11.0.0.0", isPublic: true),
        .init(text: "100.63.255.255", isPublic: true),
        .init(text: "100.128.0.0", isPublic: true),
        .init(text: "169.253.255.255", isPublic: true),
        .init(text: "169.255.0.0", isPublic: true),
        .init(text: "172.15.255.255", isPublic: true),
        .init(text: "172.32.0.0", isPublic: true),
        .init(text: "192.0.1.0", isPublic: true),
        .init(text: "192.167.255.255", isPublic: true),
        .init(text: "192.169.0.0", isPublic: true),
        .init(text: "168.63.129.15", isPublic: true),
        .init(text: "223.255.255.255", isPublic: true),
        // Unspecified ("this network").
        .init(text: "0.0.0.0", isPublic: false),
        .init(text: "0.255.255.255", isPublic: false),
        // Loopback.
        .init(text: "127.0.0.1", isPublic: false),
        .init(text: "127.255.255.254", isPublic: false),
        // RFC 1918.
        .init(text: "10.0.0.1", isPublic: false),
        .init(text: "10.255.255.255", isPublic: false),
        .init(text: "172.16.0.0", isPublic: false),
        .init(text: "172.31.255.255", isPublic: false),
        .init(text: "192.168.0.1", isPublic: false),
        .init(text: "192.168.255.255", isPublic: false),
        // CGNAT 100.64/10, which also holds the Alibaba metadata address.
        .init(text: "100.64.0.0", isPublic: false),
        .init(text: "100.127.255.255", isPublic: false),
        .init(text: "100.100.100.200", isPublic: false),
        // Link-local, including the AWS/GCP/Azure/OCI metadata address
        // (and what metadata.google.internal resolves to).
        .init(text: "169.254.0.1", isPublic: false),
        .init(text: "169.254.169.254", isPublic: false),
        .init(text: "169.254.170.2", isPublic: false),
        // Azure WireServer: a platform endpoint in public space.
        .init(text: "168.63.129.16", isPublic: false),
        // IETF protocol assignments (NAT64 discovery 192.0.0.170/171, DS-Lite).
        .init(text: "192.0.0.1", isPublic: false),
        .init(text: "192.0.0.170", isPublic: false),
        .init(text: "192.0.0.192", isPublic: false),
        // Deprecated 6to4 relay anycast.
        .init(text: "192.88.99.1", isPublic: false),
        // Documentation and benchmarking.
        .init(text: "192.0.2.1", isPublic: false),
        .init(text: "198.51.100.2", isPublic: false),
        .init(text: "203.0.113.3", isPublic: false),
        .init(text: "198.18.0.1", isPublic: false),
        .init(text: "198.19.255.255", isPublic: false),
        // Multicast, reserved, broadcast.
        .init(text: "224.0.0.1", isPublic: false),
        .init(text: "239.255.255.255", isPublic: false),
        .init(text: "240.0.0.1", isPublic: false),
        .init(text: "255.255.255.255", isPublic: false),
    ]

    static let ipv6Cases: [AddressCase] = [
        // Global unicast.
        .init(text: "2606:4700:4700::1111", isPublic: true),
        .init(text: "2001:4860:4860::8888", isPublic: true),
        .init(text: "2001:200::1", isPublic: true),
        .init(text: "2a00:1450:4001::1", isPublic: true),
        .init(text: "3ffe::1", isPublic: true),
        // Unspecified and loopback.
        .init(text: "::", isPublic: false),
        .init(text: "::1", isPublic: false),
        // Link-local, deprecated site-local, ULA (incl. the AWS IPv6
        // metadata address), multicast.
        .init(text: "fe80::1", isPublic: false),
        .init(text: "febf:ffff::1", isPublic: false),
        .init(text: "fec0::1", isPublic: false),
        .init(text: "fc00::1", isPublic: false),
        .init(text: "fd00:ec2::254", isPublic: false),
        .init(text: "ff02::1", isPublic: false),
        .init(text: "ff0e::1", isPublic: false),
        // Outside 2000::/3: discard-only, SRv6 SIDs, unallocated.
        .init(text: "100::1", isPublic: false),
        .init(text: "5f00::1", isPublic: false),
        .init(text: "4000::1", isPublic: false),
        .init(text: "e000::1", isPublic: false),
        // 2001::/23 IETF protocol assignments: Teredo, benchmarking, AMT,
        // AS112, ORCHID v1/v2.
        .init(text: "2001::1", isPublic: false),
        .init(text: "2001:2::1", isPublic: false),
        .init(text: "2001:3::1", isPublic: false),
        .init(text: "2001:4:112::1", isPublic: false),
        .init(text: "2001:10::1", isPublic: false),
        .init(text: "2001:20::1", isPublic: false),
        .init(text: "2001:1ff:ffff::1", isPublic: false),
        // Documentation.
        .init(text: "2001:db8::1", isPublic: false),
        .init(text: "3fff::1", isPublic: false),
        .init(text: "3fff:fff::1", isPublic: false),
        // IPv4-mapped: the embedded IPv4 decides.
        .init(text: "::ffff:8.8.8.8", isPublic: true),
        .init(text: "::ffff:127.0.0.1", isPublic: false),
        .init(text: "::ffff:10.0.0.1", isPublic: false),
        .init(text: "::ffff:169.254.169.254", isPublic: false),
        .init(text: "::ffff:100.100.100.200", isPublic: false),
        .init(text: "::ffff:0.0.0.0", isPublic: false),
        // IPv4-translated (SIIT, ::ffff:0:0:0/96).
        .init(text: "::ffff:0:808:808", isPublic: true),
        .init(text: "::ffff:0:a9fe:a9fe", isPublic: false),
        .init(text: "::ffff:0:7f00:1", isPublic: false),
        // Deprecated IPv4-compatible.
        .init(text: "::8.8.8.8", isPublic: true),
        .init(text: "::10.0.0.1", isPublic: false),
        .init(text: "::169.254.169.254", isPublic: false),
        // 6to4 embeds the IPv4 in bits 16-47.
        .init(text: "2002:808:808::1", isPublic: true),
        .init(text: "2002:a9fe:a9fe::1", isPublic: false),
        .init(text: "2002:c0a8:101::1", isPublic: false),
        // NAT64 well-known prefix 64:ff9b::/96: the embedded IPv4 decides.
        .init(text: "64:ff9b::808:808", isPublic: true),
        .init(text: "64:ff9b::a9fe:a9fe", isPublic: false),
        .init(text: "64:ff9b::a00:1", isPublic: false),
        .init(text: "64:ff9b::7f00:1", isPublic: false),
        // The rest of 64:ff9b::/32, including the 64:ff9b:1::/48 local-use
        // block whose operator-chosen layout makes the embedding ambiguous.
        .init(text: "64:ff9b:1:808:8:800::", isPublic: false),
        .init(text: "64:ff9b:1::808:808", isPublic: false),
        .init(text: "64:ff9b:2::808:808", isPublic: false),
        .init(text: "64:ff9b:0:0:1::808:808", isPublic: false),
    ]

    @Test(arguments: ipv4Cases)
    func ipv4Classifier(_ entry: AddressCase) throws {
        let bytes = try #require(Self.bytes(AF_INET, entry.text))
        let hostOrder = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(EgressWire.isPublicIPv4(hostOrder) == entry.isPublic)
        // The sockaddr entry point agrees with the pure verdict.
        #expect(Self.sockaddrVerdict(AF_INET, bytes) == entry.isPublic)
    }

    @Test(arguments: ipv6Cases)
    func ipv6Classifier(_ entry: AddressCase) throws {
        let bytes = try #require(Self.bytes(AF_INET6, entry.text))
        #expect(EgressWire.isPublicIPv6(bytes) == entry.isPublic)
        #expect(Self.sockaddrVerdict(AF_INET6, bytes) == entry.isPublic)
    }

    @Test func ipv6ClassifierRejectsWrongLengths() {
        #expect(EgressWire.isPublicIPv6([]) == false)
        #expect(EgressWire.isPublicIPv6([UInt8](repeating: 0x26, count: 15)) == false)
        #expect(EgressWire.isPublicIPv6([UInt8](repeating: 0x26, count: 17)) == false)
    }

    // MARK: Literal targets through the production resolver

    /// Numeric literals resolve without DNS, so the production dial path
    /// is exercised offline: the literal passes the same filter as a name.
    @Test(arguments: [
        "169.254.169.254", "10.0.0.1", "100.100.100.200", "127.0.0.1",
        "::ffff:169.254.169.254", "fd00:ec2::254", "fe80::1", "::1",
        "64:ff9b::a9fe:a9fe",
    ])
    func literalTargetsAreFilteredByTheProductionDial(_ literal: String) {
        #expect(EgressProxy.dial(host: literal, port: 443, external: true) == .addressFiltered)
    }

    // MARK: Bounded resolution

    @Test func resolutionThatOutlivesTheDeadlineFailsClosed() {
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        let answer = EgressProxy.resolveWithDeadline(
            host: "slow.example", port: 443, timeout: .milliseconds(200),
            budget: EgressResolverBudget(limit: 4),
            resolve: { _, _ in
                _ = release.wait(timeout: .now() + 5)
                return [Self.candidateV4("8.8.8.8", port: 443)!]
            }
        )
        release.signal()
        #expect(answer.isEmpty)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func resolutionWithinTheDeadlineReturnsTheAnswer() throws {
        let candidate = try #require(Self.candidateV4("8.8.8.8", port: 443))
        let answer = EgressProxy.resolveWithDeadline(
            host: "fast.example", port: 443, timeout: .seconds(5),
            budget: EgressResolverBudget(limit: 4),
            resolve: { _, _ in [candidate] }
        )
        #expect(answer.count == 1)
    }

    @Test func exhaustedResolverBudgetFailsClosedWithoutResolving() throws {
        let budget = EgressResolverBudget(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        // Holds the only slot until released.
        _ = EgressProxy.resolveWithDeadline(
            host: "hung.example", port: 443, timeout: .milliseconds(50), budget: budget,
            resolve: { _, _ in
                calls.withLock { $0 += 1 }
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return []
            }
        )
        // The deadline can pass before the lookup is scheduled; wait until
        // it actually holds the slot before asserting the call count.
        try #require(started.wait(timeout: .now() + 5) == .success)
        let second = EgressProxy.resolveWithDeadline(
            host: "next.example", port: 443, timeout: .seconds(1), budget: budget,
            resolve: { _, _ in
                calls.withLock { $0 += 1 }
                return [Self.candidateV4("8.8.8.8", port: 443)!]
            }
        )
        #expect(second.isEmpty)
        #expect(calls.withLock { $0 } == 1)
        release.signal()
        // The slot frees once the hung lookup returns.
        var freed = false
        for _ in 0..<250 where freed == false {
            freed = budget.acquire()
            if freed { budget.release() } else { usleep(20_000) }
        }
        #expect(freed)
    }

    /// One runtime's hung lookups must not starve another runtime's proxy:
    /// each proxy owns its budget, and only the process ceiling is shared.
    @Test func exhaustingOneProxyBudgetDoesNotStarveAnother() throws {
        let ceiling = EgressResolverBudget(limit: 8)
        let first = EgressResolverBudget(limit: 2, parent: ceiling)
        let second = EgressResolverBudget(limit: 2, parent: ceiling)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        defer { for _ in 0..<2 { release.signal() } }
        for index in 0..<2 {
            _ = EgressProxy.resolveWithDeadline(
                host: "hung\(index).example", port: 443, timeout: .milliseconds(20), budget: first,
                resolve: { _, _ in
                    started.signal()
                    _ = release.wait(timeout: .now() + 5)
                    return []
                }
            )
        }
        for _ in 0..<2 { try #require(started.wait(timeout: .now() + 5) == .success) }
        let candidate = try #require(Self.candidateV4("8.8.8.8", port: 443))
        let starved = EgressProxy.resolveWithDeadline(
            host: "next.example", port: 443, timeout: .seconds(5), budget: first,
            resolve: { _, _ in [candidate] }
        )
        let other = EgressProxy.resolveWithDeadline(
            host: "next.example", port: 443, timeout: .seconds(5), budget: second,
            resolve: { _, _ in [candidate] }
        )
        #expect(starved.isEmpty)
        #expect(other.count == 1)
    }

    @Test func processCeilingBoundsLookupsAcrossProxyBudgets() {
        let ceiling = EgressResolverBudget(limit: 3)
        let first = EgressResolverBudget(limit: 2, parent: ceiling)
        let second = EgressResolverBudget(limit: 2, parent: ceiling)
        #expect(first.acquire())
        #expect(first.acquire())
        #expect(second.acquire())
        // Ceiling spent: the second proxy still has a local slot but is denied,
        // and the failed attempt must not leak that local slot.
        #expect(second.acquire() == false)
        first.release()
        #expect(second.acquire())
        #expect(second.acquire() == false)
    }

    /// Production proxies each get their own budget under the shared
    /// process ceiling, so spending one proxy's slots leaves the other's
    /// lookups working.
    @Test func eachProxyInstanceOwnsItsResolverBudget() throws {
        let first = EgressProxy(policy: .publicHTTPS, grants: nil, record: { _ in })
        let second = EgressProxy(policy: .publicHTTPS, grants: nil, record: { _ in })
        #expect(first.resolverBudget !== second.resolverBudget)
        #expect(first.resolverBudget.parent === EgressResolverBudget.processCeiling)
        #expect(EgressResolverBudget.processCeiling.limit > first.resolverBudget.limit)
        var held = 0
        while first.resolverBudget.acquire() { held += 1 }
        defer { for _ in 0..<held { first.resolverBudget.release() } }
        #expect(held == first.resolverBudget.limit)
        #expect(first.resolve("localhost", 80).isEmpty)
        #expect(second.resolve("localhost", 80).isEmpty == false)
    }

    // MARK: Proxy wiring

    /// A name whose answer mixes a public and a private address is denied
    /// as address-filtered and neither address is dialed.
    @Test func proxyDeniesMixedPublicPrivateAnswerWithoutDialing() throws {
        let listener = try #require(LoopbackListener())
        let publicCandidate = try #require(Self.candidateV4("8.8.8.8", port: 443))
        let privateCandidate = try #require(Self.candidateV4("127.0.0.1", port: listener.port))
        let resolver = CountingResolver(answer: [publicCandidate, privateCandidate])
        let collector = DenialCollector()
        let proxy = EgressProxy(
            policy: .publicHTTPS, grants: nil, record: { collector.record($0) },
            resolve: resolver.resolve
        )
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let response = try Self.connect(proxyPort: port, request: "CONNECT mixed.example.com:443 HTTP/1.1\r\n\r\n")
        #expect(response.contains("HTTP/1.1 403"))
        collector.await(count: 1)
        #expect(collector.all.map(\.reason) == [.addressFiltered])
        #expect(collector.all.first?.host == "mixed.example.com")
        #expect(resolver.calls == 1)
        #expect(listener.acceptedConnection(withinMilliseconds: 300) == false)
    }

    @Test(arguments: [
        ["169.254.169.254"], ["10.0.0.5", "8.8.8.8"], ["8.8.8.8", "100.100.100.200"],
    ])
    func proxyDeniesNamesResolvingToMetadataOrPrivateAddresses(_ answer: [String]) throws {
        let candidates = answer.compactMap { Self.candidateV4($0, port: 443) }
        #expect(candidates.count == answer.count)
        let resolver = CountingResolver(answer: candidates)
        let collector = DenialCollector()
        let proxy = EgressProxy(
            policy: .publicHTTPS, grants: nil, record: { collector.record($0) },
            resolve: resolver.resolve
        )
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let response = try Self.connect(
            proxyPort: port, request: "CONNECT metadata.google.internal:443 HTTP/1.1\r\n\r\n"
        )
        #expect(response.contains("HTTP/1.1 403"))
        collector.await(count: 1)
        #expect(collector.all.map(\.reason) == [.addressFiltered])
    }

    @Test func proxyDeniesEmptyAndTimedOutResolutionAsDNSFailure() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let budget = EgressResolverBudget(limit: 4)
        let collector = DenialCollector()
        let proxy = EgressProxy(
            policy: .publicHTTPS, grants: nil, record: { collector.record($0) },
            resolve: { host, port in
                EgressProxy.resolveWithDeadline(
                    host: host, port: port, timeout: .milliseconds(200), budget: budget,
                    resolve: { name, _ in
                        if name == "hung.example.com" { _ = release.wait(timeout: .now() + 5) }
                        return []
                    }
                )
            }
        )
        let port = try proxy.start().get()
        defer { proxy.stop() }
        for name in ["hung.example.com", "empty.example.com"] {
            let response = try Self.connect(proxyPort: port, request: "CONNECT \(name):443 HTTP/1.1\r\n\r\n")
            #expect(response.contains("HTTP/1.1 403"))
        }
        collector.await(count: 2)
        #expect(collector.all.map(\.reason) == [.dnsFailed, .dnsFailed])
    }

    /// Literal private/metadata targets never reach the resolver: external
    /// admission takes DNS names only, and the loopback door admits only
    /// 127/8 and `localhost`.
    @Test(arguments: [
        "169.254.169.254:443", "10.0.0.1:443", "100.100.100.200:80", "192.168.1.1:80",
        "169.254.43518:443", "2852039166:443", "0251.0376.0251.0376:443",
    ])
    func proxyDeniesLiteralPrivateTargets(_ authority: String) throws {
        let resolver = CountingResolver(answer: [])
        let collector = DenialCollector()
        let proxy = EgressProxy(
            policy: .publicHTTPS, grants: nil, record: { collector.record($0) },
            resolve: resolver.resolve
        )
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let response = try Self.connect(proxyPort: port, request: "CONNECT \(authority) HTTP/1.1\r\n\r\n")
        #expect(response.contains("HTTP/1.1 403"))
        collector.await(count: 1)
        #expect(collector.all.map(\.reason) == [.deniedPolicy])
        #expect(resolver.calls == 0)
    }

    /// Credentialed allowlist tunnels check the SNI first and then resolve:
    /// a mixed answer still closes the tunnel and records address-filtered.
    @Test func credentialedTunnelDeniesMixedAnswerAfterSNI() throws {
        let publicCandidate = try #require(Self.candidateV4("8.8.8.8", port: 443))
        let metadata = try #require(Self.candidateV4("169.254.169.254", port: 443))
        let resolver = CountingResolver(answer: [publicCandidate, metadata])
        let collector = DenialCollector()
        let credential = EgressProxyCredential()
        let grant = EgressGrant(
            principal: EgressPrincipal(rawValue: "runtime-a"),
            policy: EgressHostPolicy(allowedHosts: ["api.example.com"])
        )
        let proxy = EgressProxy(
            policy: .publicHTTPS, grants: [credential: grant], record: { collector.record($0) },
            resolve: resolver.resolve
        )
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let client = try #require(Self.dialLoopback(port: port))
        defer { close(client) }
        #expect(Self.send(client, Array(
            "CONNECT api.example.com:443 HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n".utf8
        )))
        #expect(Self.read(client).contains("HTTP/1.1 200"))
        #expect(Self.send(client, Self.clientHello("api.example.com")))
        collector.await(count: 1)
        #expect(collector.all.map(\.reason) == [.addressFiltered])
        #expect(resolver.calls == 1)
    }

    /// The proxy dials the exact sockaddr it checked: the resolver answers
    /// with a different loopback port than the CONNECT asked for, and the
    /// tunnel lands on the resolved one. Nothing resolves the name again.
    @Test func proxyDialsTheCheckedAddressWithoutReResolving() throws {
        let listener = try #require(LoopbackListener())
        let pinned = try #require(Self.candidateV4("127.0.0.1", port: listener.port))
        let resolver = CountingResolver(answer: [pinned])
        let collector = DenialCollector()
        let proxy = EgressProxy(
            policy: .publicHTTPS, grants: nil, record: { collector.record($0) },
            resolve: resolver.resolve
        )
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let client = try #require(Self.dialLoopback(port: port))
        defer { close(client) }
        #expect(Self.send(client, Array("CONNECT 127.0.0.1:9 HTTP/1.1\r\n\r\n".utf8)))
        #expect(Self.read(client).contains("HTTP/1.1 200"))
        #expect(listener.acceptedConnection(withinMilliseconds: 5_000))
        #expect(resolver.calls == 1)
        #expect(collector.all.isEmpty)
    }
}

// MARK: - Helpers

extension EgressDestinationCheckTests {
    static func bytes(_ family: Int32, _ text: String) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let parsed = buffer.withUnsafeMutableBytes { raw in
            inet_pton(family, text, raw.baseAddress)
        }
        return parsed == 1 ? buffer : nil
    }

    static func sockaddrVerdict(_ family: Int32, _ bytes: [UInt8]) -> Bool {
        var storage = sockaddr_storage()
        withUnsafeMutablePointer(to: &storage) { pointer in
            if family == AF_INET {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                    address.pointee.sin_family = sa_family_t(AF_INET)
                    withUnsafeMutableBytes(of: &address.pointee.sin_addr) { $0.copyBytes(from: bytes) }
                }
            } else {
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                    address.pointee.sin6_family = sa_family_t(AF_INET6)
                    withUnsafeMutableBytes(of: &address.pointee.sin6_addr) { $0.copyBytes(from: bytes) }
                }
            }
        }
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, EgressProxy.isPublicUnicast)
        }
    }

    static func candidateV4(_ text: String, port: Int) -> EgressDialCandidate? {
        guard let bytes = bytes(AF_INET, text) else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
        var storage = sockaddr_storage()
        withUnsafeBytes(of: &address) { raw in
            withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: raw) }
        }
        #if canImport(Darwin)
        let socktype: Int32 = SOCK_STREAM
        #else
        let socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        return EgressDialCandidate(
            family: AF_INET, socktype: socktype, proto: Int32(IPPROTO_TCP),
            address: storage, length: socklen_t(MemoryLayout<sockaddr_in>.size)
        )
    }

    static func streamSocket() -> Int32 {
        #if canImport(Darwin)
        socket(AF_INET, SOCK_STREAM, 0)
        #else
        socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    static func dialLoopback(port: Int) -> Int32? {
        let fd = streamSocket()
        guard fd >= 0 else { return nil }
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                posixSend(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// Reads until the peer closes, a status line arrives, or 10 s pass.
    static func read(_ fd: Int32) -> String {
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            collected += buffer[..<count]
            if String(decoding: collected, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    static func connect(proxyPort: Int, request: String) throws -> String {
        let client = try #require(dialLoopback(port: proxyPort))
        defer { close(client) }
        #expect(send(client, Array(request.utf8)))
        return read(client)
    }

    /// Minimal TLS 1.3 ClientHello record carrying an SNI host_name.
    static func clientHello(_ host: String) -> [UInt8] {
        let name = Array(host.utf8)
        let entry: [UInt8] = [0x00, UInt8(name.count >> 8), UInt8(name.count & 0xFF)] + name
        let list: [UInt8] = [UInt8(entry.count >> 8), UInt8(entry.count & 0xFF)] + entry
        let extensions: [UInt8] = [0x00, 0x00, UInt8(list.count >> 8), UInt8(list.count & 0xFF)] + list
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 32) + [0x00]
        body += [0x00, 0x02, 0x13, 0x01, 0x01, 0x00]
        body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xFF)] + extensions
        let handshake: [UInt8] = [0x01, UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF),
                                  UInt8(body.count & 0xFF)] + body
        return [0x16, 0x03, 0x01, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xFF)] + handshake
    }
}

private func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(fd, address, length)
}

private func posixSend(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int, _ flags: Int32) -> Int {
    send(fd, base, count, flags)
}

private final class CountingResolver: Sendable {
    private let answer: [EgressDialCandidate]
    private let count = Mutex(0)

    init(answer: [EgressDialCandidate]) {
        self.answer = answer
    }

    var calls: Int { count.withLock { $0 } }

    var resolve: @Sendable (String, Int) -> [EgressDialCandidate] {
        { [self] _, _ in
            count.withLock { $0 += 1 }
            return answer
        }
    }
}

private final class DenialCollector: Sendable {
    private let denials = Mutex<[EgressProxyDenial]>([])

    func record(_ denial: EgressProxyDenial) {
        denials.withLock { $0.append(denial) }
    }

    var all: [EgressProxyDenial] { denials.withLock { $0 } }

    /// Denials land on the relay queue after the reply; wait for them.
    func await(count: Int) {
        for _ in 0..<200 where all.count < count {
            usleep(25_000)
        }
    }
}

/// A loopback listener that only observes whether anything connected.
private final class LoopbackListener: Sendable {
    let port: Int
    private let fd: Int32

    init?() {
        let fd = EgressDestinationCheckTests.streamSocket()
        guard fd >= 0 else { return nil }
        var address = EgressDestinationCheckTests.loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fetched = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, listen(fd, 4) == 0, fetched == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: name.sin_port))
    }

    deinit {
        close(fd)
    }

    func acceptedConnection(withinMilliseconds milliseconds: Int32) -> Bool {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, milliseconds) > 0 else { return false }
        let accepted = accept(fd, nil, nil)
        if accepted >= 0 { close(accepted) }
        return accepted >= 0
    }
}
