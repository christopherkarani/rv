#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Owner-set `allowed_ips` at the proxy: which answer sets an endpoint's
/// private ranges admit, that the dial connects the exact vetted address
/// from one resolution (no rebinding window), and that only a policy
/// admission carries the ranges. No packet leaves the host: the connect
/// seam records the vetted candidate instead of dialing it.
@Suite struct EgressAllowedIPsDialTests {
    static let host = "staging.corp.lan"

    static func list(_ entries: [String]) throws -> EgressAllowedIPs {
        try EgressAllowedIPs(parsing: entries)
    }

    static func v4(_ text: String, port: Int = 443) throws -> EgressDialCandidate {
        try #require(EgressDestinationCheckTests.candidateV4(text, port: port))
    }

    static func v6(_ text: String, port: Int = 443, scope: UInt32 = 0) throws -> EgressDialCandidate {
        let bytes = try #require(EgressDestinationCheckTests.bytes(AF_INET6, text))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port)).bigEndian
        address.sin6_scope_id = scope
        withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
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
            family: AF_INET6, socktype: socktype, proto: Int32(IPPROTO_TCP),
            address: storage, length: socklen_t(MemoryLayout<sockaddr_in6>.size)
        )
    }

    static func shown(_ candidate: EgressDialCandidate) -> String {
        EgressProxy.coverageAddress(of: candidate)?.description ?? "unscoped?"
    }

    // MARK: Answer-set verdict

    struct AnswerCase: Sendable, CustomTestStringConvertible {
        var answer: [String]
        var allowed: [String]?
        var admitted: Bool
        var testDescription: String {
            "\(answer) under \(allowed.map { "\($0)" } ?? "public-only") -> \(admitted ? "dial" : "filtered")"
        }
    }

    static let answerCases: [AnswerCase] = [
        // Public unicast is unchanged with or without a list.
        .init(answer: ["8.8.8.8"], allowed: nil, admitted: true),
        .init(answer: ["8.8.8.8"], allowed: ["10.0.5.0/24"], admitted: true),
        // Private is refused without a list, and outside it.
        .init(answer: ["10.0.5.20"], allowed: nil, admitted: false),
        .init(answer: ["10.0.5.20"], allowed: ["10.0.5.0/24"], admitted: true),
        .init(answer: ["10.0.5.20"], allowed: ["10.0.5.20/32"], admitted: true),
        .init(answer: ["10.0.6.20"], allowed: ["10.0.5.0/24"], admitted: false),
        .init(answer: ["192.168.1.10", "192.168.1.11"], allowed: ["192.168.1.0/24"], admitted: true),
        // Every address must be covered: one stray private or public
        // address in a non-public answer refuses the whole set.
        .init(answer: ["10.0.5.20", "10.0.6.20"], allowed: ["10.0.5.0/24"], admitted: false),
        .init(answer: ["10.0.5.20", "8.8.8.8"], allowed: ["10.0.5.0/24"], admitted: false),
        .init(answer: ["8.8.8.8", "10.0.5.20"], allowed: ["10.0.5.0/24", "8.8.8.0/24"], admitted: true),
        // Forbidden addresses never pass, even beside covered ones.
        .init(answer: ["10.0.5.20", "169.254.169.254"], allowed: ["10.0.5.0/24"], admitted: false),
        .init(answer: ["10.0.5.20", "127.0.0.1"], allowed: ["10.0.5.0/24"], admitted: false),
        .init(answer: ["100.100.100.200"], allowed: ["100.100.100.0/25"], admitted: false),
        // CGNAT (e.g. a tailnet) opens only where listed.
        .init(answer: ["100.101.102.103"], allowed: ["100.101.102.103/32"], admitted: true),
    ]

    @Test(arguments: answerCases)
    func answerSetVerdict(_ row: AnswerCase) throws {
        let candidates = try row.answer.map { try Self.v4($0) }
        let allowed = try row.allowed.map(Self.list)
        #expect(EgressProxy.externalAnswerAdmitted(candidates, allowedIPs: allowed, localAddresses: { [] }) == row.admitted)
    }

    /// A range that includes this machine's own interface address (the Mac
    /// at 192.168.1.10 inside 192.168.1.0/24) must not let the cage reach
    /// host services: an answer equal to a local address is refused, in
    /// IPv4 or mapped form; its neighbours still pass.
    @Test func answerEqualToALocalInterfaceAddressIsRefused() throws {
        let allowed = try Self.list(["192.168.1.0/24", "fd12:3456:789a::/48"])
        let local: Set<EgressIPAddress> = [
            try #require(EgressIPAddress(parsing: "192.168.1.10")),
            try #require(EgressIPAddress(parsing: "fd12:3456:789a::10")),
        ]
        func admitted(_ answer: [EgressDialCandidate]) -> Bool {
            EgressProxy.externalAnswerAdmitted(answer, allowedIPs: allowed, localAddresses: { local })
        }
        #expect(admitted([try Self.v4("192.168.1.11")]))
        #expect(admitted([try Self.v4("192.168.1.10")]) == false)
        #expect(admitted([try Self.v6("::ffff:192.168.1.10")]) == false)
        #expect(admitted([try Self.v4("192.168.1.11"), try Self.v4("192.168.1.10")]) == false)
        #expect(admitted([try Self.v6("fd12:3456:789a::10")]) == false)
        #expect(admitted([try Self.v6("fd12:3456:789a::11")]))
    }

    /// Interfaces that cannot be listed deny every private-range answer;
    /// public answers do not depend on the listing.
    @Test func unlistableInterfacesDenyPrivateRangeAnswers() throws {
        let allowed = try Self.list(["10.0.5.0/24"])
        let covered = try Self.v4("10.0.5.20")
        #expect(EgressProxy.externalAnswerAdmitted([covered], allowedIPs: allowed, localAddresses: { nil }) == false)
        #expect(EgressProxy.externalAnswerAdmitted([try Self.v4("8.8.8.8")], allowedIPs: allowed, localAddresses: { nil }))
        let dialed = DialedAddresses()
        let outcome = EgressProxy.dial(
            host: Self.host, port: 443, external: true, allowedIPs: allowed,
            resolve: { _, _ in [covered] }, connect: { dialed.record($0) }, localAddresses: { nil }
        )
        #expect(outcome == .addressFiltered)
        #expect(dialed.all.isEmpty)
    }

    /// The production listing sees this machine's loopback interface.
    @Test func localInterfaceAddressesListsLoopback() throws {
        let local = try #require(EgressProxy.localInterfaceAddresses())
        #expect(local.contains(try #require(EgressIPAddress(parsing: "127.0.0.1"))))
    }

    /// `::ffff:10.0.5.20` is the IPv4 host 10.0.5.20: an IPv4 list covers
    /// it, and a mapped loopback or metadata address stays forbidden.
    @Test func mappedIPv6AnswersAreJudgedAsIPv4() throws {
        let allowed = try Self.list(["10.0.5.0/24"])
        #expect(EgressProxy.externalAnswerAdmitted([try Self.v6("::ffff:10.0.5.20")], allowedIPs: allowed))
        #expect(EgressProxy.externalAnswerAdmitted([try Self.v6("::ffff:10.0.6.20")], allowedIPs: allowed) == false)
        for forbidden in ["::ffff:127.0.0.1", "::ffff:169.254.169.254", "::1", "fe80::1", "fd00:ec2::254"] {
            #expect(
                EgressProxy.externalAnswerAdmitted([try Self.v6(forbidden)], allowedIPs: allowed) == false,
                "\(forbidden)")
        }
    }

    /// A scoped IPv6 answer is refused: the scope picks an interface the
    /// owner's list does not name. The same address unscoped passes.
    @Test func scopedIPv6AnswersAreRefused() throws {
        let allowed = try Self.list(["fd12:3456:789a::/48"])
        #expect(EgressProxy.externalAnswerAdmitted([try Self.v6("fd12:3456:789a::10")], allowedIPs: allowed))
        #expect(
            EgressProxy.externalAnswerAdmitted([try Self.v6("fd12:3456:789a::10", scope: 3)], allowedIPs: allowed)
                == false)
        #expect(EgressProxy.coverageAddress(of: try Self.v6("fd12:3456:789a::10", scope: 3)) == nil)
    }

    @Test func truncatedOrUnknownCandidatesAreRefused() throws {
        let allowed = try Self.list(["10.0.5.0/24"])
        var short = try Self.v4("10.0.5.20")
        short.length = 4
        #expect(EgressProxy.coverageAddress(of: short) == nil)
        #expect(EgressProxy.externalAnswerAdmitted([short], allowedIPs: allowed) == false)
        var unknown = try Self.v4("10.0.5.20")
        unknown.address.ss_family = sa_family_t(AF_UNIX)
        #expect(EgressProxy.coverageAddress(of: unknown) == nil)
    }

    // MARK: Dial pin

    /// The rebinding pin: the resolver answers a covered private address
    /// first and the metadata address on every later lookup. `dial`
    /// resolves once and connects exactly the address it checked.
    @Test func dialConnectsTheVettedAddressFromOneResolution() throws {
        let covered = try Self.v4("10.0.5.20")
        let rebound = try Self.v4("169.254.169.254")
        let resolver = RebindingResolver(first: [covered], later: [rebound])
        let dialed = DialedAddresses()
        let outcome = EgressProxy.dial(
            host: Self.host, port: 443, external: true, allowedIPs: try Self.list(["10.0.5.0/24"]),
            resolve: { resolver.resolve($0, $1) }, connect: { dialed.record($0) }
        )
        #expect(outcome == .connectFailed)
        #expect(resolver.calls == 1)
        #expect(dialed.all == ["10.0.5.20"])
    }

    /// Without the list the same answer is filtered and nothing is dialed.
    @Test func dialWithoutAllowedIPsFiltersPrivateAnswersBeforeConnecting() throws {
        let resolver = RebindingResolver(first: [try Self.v4("10.0.5.20")], later: [])
        let dialed = DialedAddresses()
        let outcome = EgressProxy.dial(
            host: Self.host, port: 443, external: true, allowedIPs: nil,
            resolve: { resolver.resolve($0, $1) }, connect: { dialed.record($0) }
        )
        #expect(outcome == .addressFiltered)
        #expect(dialed.all.isEmpty)
    }

    @Test func dialRefusesPartiallyCoveredAnswerWithoutConnecting() throws {
        let resolver = RebindingResolver(first: [try Self.v4("10.0.5.20"), try Self.v4("8.8.8.8")], later: [])
        let dialed = DialedAddresses()
        let outcome = EgressProxy.dial(
            host: Self.host, port: 443, external: true, allowedIPs: try Self.list(["10.0.5.0/24"]),
            resolve: { resolver.resolve($0, $1) }, connect: { dialed.record($0) }
        )
        #expect(outcome == .addressFiltered)
        #expect(dialed.all.isEmpty)
    }

    // MARK: Admission

    static func decide(
        _ policy: EgressHostPolicy, host: String = host, port: Int = 443, credentialed: Bool = true,
        shape: EgressRequestShape = .connect, supplement: Bool = false
    ) -> EgressAdmissionVerdict {
        EgressAdmission.decide(
            target: EgressTarget(host: host, port: port), shape: shape,
            credential: credentialed ? .granted(policy) : .open(policy), binaryGateDenial: nil,
            supplementAllows: supplement
        )
    }

    @Test func policyAdmissionCarriesTheEndpointRanges() throws {
        let allowed = try Self.list(["10.0.5.0/24"])
        let policy = EgressHostPolicy(
            allowedHosts: [Self.host, "api.example.com"], allowedIPs: [Self.host: allowed], relaysLoopback: false
        )
        #expect(Self.decide(policy) == .tunnel(external: true, requireSNI: true, allowedIPs: allowed))
        #expect(Self.decide(policy, host: "STAGING.corp.lan.") == .tunnel(external: true, requireSNI: true, allowedIPs: allowed))
        #expect(Self.decide(policy, host: "api.example.com") == .tunnel(external: true, requireSNI: true, allowedIPs: nil))
    }

    /// A live supplement rule is an agent proposal a human approved: it
    /// admits host:port on the public filter only, even for a host the
    /// owner gave private ranges on another port.
    @Test func supplementAdmissionNeverCarriesRanges() throws {
        let allowed = try Self.list(["10.0.5.0/24"])
        let policy = EgressHostPolicy(allowedHosts: [Self.host], allowedIPs: [Self.host: allowed])
        let verdict = Self.decide(policy, port: 8443, credentialed: false, supplement: true)
        #expect(verdict == .tunnel(external: true, requireSNI: false, allowedIPs: nil))
        let forward = Self.decide(policy, port: 80, credentialed: false, shape: .absoluteHTTP, supplement: true)
        #expect(forward == .forward(external: true, allowedIPs: nil))
    }

    // MARK: Proxy wiring

    /// End to end through a credentialed allowlist proxy (the MCP sandbox
    /// shape): the endpoint's covered private answer reaches the connect
    /// seam with the vetted address; an uncovered one is address-filtered
    /// before any connect.
    @Test func credentialedProxyDialsCoveredPrivateAnswerOnly() throws {
        let allowed = try Self.list(["10.0.5.0/24"])
        for (answer, expectDial) in [("10.0.5.20", true), ("10.0.6.20", false)] {
            let resolver = RebindingResolver(first: [try Self.v4(answer)], later: [try Self.v4("169.254.169.254")])
            let dialed = DialedAddresses()
            let denials = Mutex<[EgressDenialReason]>([])
            let credential = EgressProxyCredential()
            let grant = EgressGrant(
                principal: EgressPrincipal(rawValue: "mcp:staging"),
                policy: EgressHostPolicy(allowedHosts: [Self.host], allowedIPs: [Self.host: allowed], relaysLoopback: false)
            )
            let proxy = EgressProxy(
                policy: .publicHTTPS, grants: [credential: grant], record: { denial in denials.withLock { $0.append(denial.reason) } },
                resolve: { resolver.resolve($0, $1) }, connect: { dialed.record($0) }
            )
            let port = try proxy.start().get()
            defer { proxy.stop() }
            let client = try #require(EgressDestinationCheckTests.dialLoopback(port: port))
            defer { close(client) }
            #expect(EgressDestinationCheckTests.send(client, Array(
                "CONNECT \(Self.host):443 HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n".utf8
            )))
            #expect(EgressDestinationCheckTests.read(client).contains("HTTP/1.1 200"))
            #expect(EgressDestinationCheckTests.send(client, EgressDestinationCheckTests.clientHello(Self.host)))
            for _ in 0..<200 where denials.withLock({ $0.isEmpty }) { usleep(25_000) }
            #expect(resolver.calls == 1)
            if expectDial {
                #expect(dialed.all == ["10.0.5.20"])
                #expect(denials.withLock { $0 } == [.dialFailed])
            } else {
                #expect(dialed.all.isEmpty)
                #expect(denials.withLock { $0 } == [.addressFiltered])
            }
        }
    }
}

/// Answers `first` on the first lookup and `later` on every one after.
private final class RebindingResolver: Sendable {
    private let first: [EgressDialCandidate]
    private let later: [EgressDialCandidate]
    private let count = Mutex(0)

    init(first: [EgressDialCandidate], later: [EgressDialCandidate]) {
        self.first = first
        self.later = later
    }

    var calls: Int { count.withLock { $0 } }

    func resolve(_ host: String, _ port: Int) -> [EgressDialCandidate] {
        let call = count.withLock { value -> Int in
            value += 1
            return value
        }
        return call == 1 ? first : later
    }
}

/// Connect seam that records the vetted address and connects nothing.
private final class DialedAddresses: Sendable {
    private let addresses = Mutex<[String]>([])

    var all: [String] { addresses.withLock { $0 } }

    func record(_ candidate: EgressDialCandidate) -> Int32? {
        let shown = EgressAllowedIPsDialTests.shown(candidate)
        addresses.withLock { $0.append(shown) }
        return nil
    }
}
