#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import RVDomain

/// The dial-address table at its interface. Every row is exercised by at
/// least one case below (`everyRangeDecidesACase`), with the edges just
/// outside a range where a prefix one bit too wide would hide.
@Suite struct DialAddressTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var text: String
        /// Read literally (the admission GET, `allowed_ips`).
        var judgment: DialJudgment
        /// Reason of the deciding range; nil for public unicast.
        var reason: String?
        /// Following an embedded IPv4 (the egress proxy).
        var dialing: DialJudgment
        var testDescription: String { "\(text) -> \(judgment)/\(dialing)" }

        static func pub(_ text: String) -> Case {
            Case(text: text, judgment: .publicUnicast, reason: nil, dialing: .publicUnicast)
        }

        static func never(_ text: String, _ reason: String) -> Case {
            Case(text: text, judgment: .never, reason: reason, dialing: .never)
        }

        static func listable(_ text: String, _ reason: String) -> Case {
            Case(text: text, judgment: .listablePrivate, reason: reason, dialing: .listablePrivate)
        }

        /// An IPv6 form with a fixed IPv4 embedding: `never` read literally,
        /// the embedded address's judgment when dialing.
        static func embedded(_ text: String, _ reason: String, dialing: DialJudgment) -> Case {
            Case(text: text, judgment: .never, reason: reason, dialing: dialing)
        }
    }

    static let ipv4Cases: [Case] = [
        // Public unicast, including the edges just outside refused ranges.
        .pub("8.8.8.8"), .pub("1.1.1.1"), .pub("142.250.72.14"),
        .pub("1.0.0.0"), .pub("9.255.255.255"), .pub("11.0.0.0"), .pub("126.255.255.255"), .pub("128.0.0.0"),
        .pub("100.63.255.255"), .pub("100.128.0.0"), .pub("169.253.255.255"), .pub("169.255.0.0"),
        .pub("172.15.255.255"), .pub("172.32.0.0"), .pub("192.167.255.255"), .pub("192.169.0.0"),
        .pub("168.63.129.15"), .pub("168.63.129.17"), .pub("191.255.255.255"), .pub("192.0.1.0"),
        .pub("192.0.3.0"), .pub("192.88.98.255"), .pub("192.88.100.0"), .pub("198.17.255.255"),
        .pub("198.20.0.0"), .pub("198.51.99.255"), .pub("198.51.101.0"), .pub("203.0.112.255"),
        .pub("203.0.114.0"), .pub("223.255.255.255"),
        .never("0.0.0.0", "unspecified"),
        .never("0.255.255.255", "unspecified"),
        .never("127.0.0.1", "loopback"),
        .never("127.255.255.254", "loopback"),
        .listable("10.0.0.0", "private network"),
        .listable("10.255.255.255", "private network"),
        .listable("172.16.0.0", "private network"),
        .listable("172.31.255.255", "private network"),
        .listable("192.168.0.1", "private network"),
        .listable("192.168.255.255", "private network"),
        .listable("100.64.0.0", "shared address space"),
        .listable("100.127.255.255", "shared address space"),
        // Alibaba's metadata address sits inside shared address space.
        .never("100.100.100.200", "cloud metadata"),
        .listable("100.100.100.199", "shared address space"),
        .listable("100.100.100.201", "shared address space"),
        // AWS, GCP, Azure and OCI metadata, and the ECS task endpoint.
        .never("169.254.0.1", "link-local and cloud metadata"),
        .never("169.254.169.254", "link-local and cloud metadata"),
        .never("169.254.170.2", "link-local and cloud metadata"),
        // Azure WireServer: a platform endpoint in public space.
        .never("168.63.129.16", "cloud platform endpoint"),
        // NAT64 discovery 192.0.0.170/171, DS-Lite, Oracle's legacy metadata.
        .never("192.0.0.1", "IETF protocol assignments and cloud metadata"),
        .never("192.0.0.170", "IETF protocol assignments and cloud metadata"),
        .never("192.0.0.192", "IETF protocol assignments and cloud metadata"),
        .never("192.88.99.0", "6to4 relay anycast"),
        .never("192.88.99.255", "6to4 relay anycast"),
        .never("192.0.2.1", "documentation"),
        .never("198.51.100.2", "documentation"),
        .never("203.0.113.3", "documentation"),
        .never("198.18.0.1", "benchmarking"),
        .never("198.19.255.255", "benchmarking"),
        .never("224.0.0.1", "multicast"),
        .never("239.255.255.255", "multicast"),
        .never("240.0.0.1", "reserved and broadcast"),
        .never("255.255.255.255", "reserved and broadcast"),
    ]

    static let ipv6Cases: [Case] = [
        // Global unicast, including the edges of refused blocks inside it.
        .pub("2606:4700:4700::1111"), .pub("2001:4860:4860::8888"), .pub("2a00:1450:4001::1"),
        .pub("2000::"), .pub("2001:200::1"), .pub("2001:dba::1"), .pub("2003::1"), .pub("3ffe::1"),
        .pub("3fff:1000::1"), .pub("3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"),
        .never("::", "unspecified, loopback and IPv4-compatible"),
        .never("::1", "unspecified, loopback and IPv4-compatible"),
        // Outside 2000::/3: discard-only, SRv6 SIDs, unallocated.
        .listable("100::1", "outside global unicast"),
        .listable("1fff:ffff::1", "outside global unicast"),
        .listable("4000::1", "outside global unicast"),
        .listable("5f00::1", "outside global unicast"),
        .listable("e000::1", "outside global unicast"),
        .listable("fc00::1", "unique local"),
        .listable("fd12:3456:789a::1", "unique local"),
        .listable("fd00:ec2::252", "unique local"),
        .listable("fd00:ec2::1:254", "unique local"),
        .never("fd00:ec2::254", "cloud metadata"),
        .never("fd00:ec2::253", "cloud DNS resolver"),
        .never("fd00:ec2::123", "cloud time service"),
        .never("fd20:ce::254", "cloud metadata"),
        .never("fe80::1", "link-local"),
        .never("febf:ffff::1", "link-local"),
        .never("fec0::1", "site-local"),
        .never("feff::1", "site-local"),
        .never("ff02::1", "multicast"),
        .never("ff0e::1", "multicast"),
        // 2001::/23: Teredo, benchmarking, AMT, AS112, ORCHID v1/v2.
        .never("2001::1", "Teredo"),
        .never("2001:0:a9fe:a9fe::1", "Teredo"),
        .never("2001:2::1", "IETF protocol assignments and benchmarking"),
        .never("2001:3::1", "IETF protocol assignments and benchmarking"),
        .never("2001:4:112::1", "IETF protocol assignments and benchmarking"),
        .never("2001:10::1", "IETF protocol assignments and benchmarking"),
        .never("2001:20::1", "IETF protocol assignments and benchmarking"),
        .never("2001:1ff:ffff::1", "IETF protocol assignments and benchmarking"),
        .never("2001:db8::1", "documentation"),
        .never("3fff::1", "documentation"),
        .never("3fff:fff::1", "documentation"),
        // IPv4-mapped.
        .embedded("::ffff:8.8.8.8", "IPv4-mapped; list the IPv4 network", dialing: .publicUnicast),
        .embedded("::ffff:127.0.0.1", "IPv4-mapped; list the IPv4 network", dialing: .never),
        .embedded("::ffff:10.0.0.1", "IPv4-mapped; list the IPv4 network", dialing: .listablePrivate),
        .embedded("::ffff:169.254.169.254", "IPv4-mapped; list the IPv4 network", dialing: .never),
        .embedded("::ffff:100.100.100.200", "IPv4-mapped; list the IPv4 network", dialing: .never),
        .embedded("::ffff:168.63.129.16", "IPv4-mapped; list the IPv4 network", dialing: .never),
        .embedded("::ffff:0.0.0.0", "IPv4-mapped; list the IPv4 network", dialing: .never),
        // IPv4-translated (SIIT).
        .embedded("::ffff:0:808:808", "IPv4-translated", dialing: .publicUnicast),
        .embedded("::ffff:0:a9fe:a9fe", "IPv4-translated", dialing: .never),
        .embedded("::ffff:0:7f00:1", "IPv4-translated", dialing: .never),
        // Deprecated IPv4-compatible.
        .embedded("::8.8.8.8", "unspecified, loopback and IPv4-compatible", dialing: .publicUnicast),
        .embedded("::10.0.0.1", "unspecified, loopback and IPv4-compatible", dialing: .listablePrivate),
        .embedded("::169.254.169.254", "unspecified, loopback and IPv4-compatible", dialing: .never),
        .embedded("::0.0.0.2", "unspecified, loopback and IPv4-compatible", dialing: .never),
        // 6to4 carries the IPv4 in bits 16-47.
        .embedded("2002:808:808::1", "6to4", dialing: .publicUnicast),
        .embedded("2002:a9fe:a9fe::1", "6to4", dialing: .never),
        .embedded("2002:7f00:1::", "6to4", dialing: .never),
        .embedded("2002:c0a8:101::1", "6to4", dialing: .listablePrivate),
        // NAT64 well-known prefix 64:ff9b::/96.
        .embedded("64:ff9b::808:808", "NAT64", dialing: .publicUnicast),
        .embedded("64:ff9b::a9fe:a9fe", "NAT64", dialing: .never),
        .embedded("64:ff9b::a00:1", "NAT64", dialing: .listablePrivate),
        .embedded("64:ff9b::7f00:1", "NAT64", dialing: .never),
        // The rest of 64:ff9b::/32, including the 64:ff9b:1::/48 local-use
        // block whose operator-chosen layout leaves the embedding ambiguous.
        .never("64:ff9b:1:808:8:800::", "NAT64"),
        .never("64:ff9b:1::808:808", "NAT64"),
        .never("64:ff9b:2::808:808", "NAT64"),
        .never("64:ff9b:0:0:1::808:808", "NAT64"),
    ]

    @Test(arguments: ipv4Cases + ipv6Cases)
    func judgesEachAddress(_ entry: Case) throws {
        let bytes = try #require(Self.bytes(entry.text))
        #expect(DialAddress.judgment(of: bytes) == entry.judgment)
        #expect(DialAddress.range(holding: bytes)?.reason == entry.reason)
        #expect(DialAddress.judgment(followingEmbeddedIPv4: bytes) == entry.dialing)
    }

    /// Every row decides at least one case, so no row goes untested.
    @Test func everyRangeDecidesACase() throws {
        var decided = Set<DialRange>()
        for entry in Self.ipv4Cases + Self.ipv6Cases {
            if let range = DialAddress.range(holding: try #require(Self.bytes(entry.text))) {
                decided.insert(range)
            }
        }
        for range in DialAddress.ranges {
            #expect(decided.contains(range), "no case is decided by \(range) (\(range.reason))")
        }
    }

    /// Rows are written as bytes: each is an IPv4 or IPv6 network with no
    /// host bits, a reachable prefix, and a refusal (public is the absence
    /// of a row).
    @Test func everyRangeIsAWellFormedRefusal() {
        for range in DialAddress.ranges {
            let width = range.network.count * 8
            #expect(range.network.count == 4 || range.network.count == 16, "\(range)")
            #expect((1...width).contains(range.prefixLength), "\(range)")
            #expect(range.contains(range.network), "\(range) has host bits set")
            #expect(range.judgment != .publicUnicast, "\(range)")
            #expect(range.reason.isEmpty == false, "\(range)")
        }
        #expect(Set(DialAddress.ranges).count == DialAddress.ranges.count)
    }

    @Test func wrongLengthsAreNever() {
        for length in [0, 3, 5, 15, 17] {
            let bytes = [UInt8](repeating: 0x26, count: length)
            #expect(DialAddress.judgment(of: bytes) == .never)
            #expect(DialAddress.judgment(followingEmbeddedIPv4: bytes) == .never)
            #expect(DialAddress.range(holding: bytes) == DialAddress.malformed)
            for prefix in [0, length * 8] {
                #expect(DialAddress.neverRange(overlapping: bytes, prefixLength: prefix) == DialAddress.malformed)
            }
        }
        #expect(DialAddress.malformed.judgment == .never)
        #expect(DialAddress.malformed.description == "malformed")
    }

    /// `allowed_ips` names the first `never` row, in table order, that an
    /// entry overlaps; listable rows never refuse.
    @Test func neverRangeIsTheFirstOverlappingRefusal() throws {
        func never(_ text: String, _ prefix: Int) throws -> String? {
            DialAddress.neverRange(overlapping: try #require(Self.bytes(text)), prefixLength: prefix)?.description
        }
        #expect(try never("10.0.0.0", 8) == nil)
        #expect(try never("100.64.0.0", 10) == "100.100.100.200/32")
        #expect(try never("0.0.0.0", 0) == "0.0.0.0/8")
        #expect(try never("2001::", 23) == "2001::/32")
        #expect(try never("fd00::", 8) == "fd00:ec2::254/128")
        #expect(try never("::fffe:0:0", 95) == "::ffff:0:0/96")
        #expect(try never("::", 64) == "::/96")
        #expect(try never("fd12::", 16) == nil)
    }

    static func bytes(_ text: String) -> [UInt8]? {
        let family = text.contains(":") ? AF_INET6 : AF_INET
        var buffer = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let parsed = buffer.withUnsafeMutableBytes { raw in
            inet_pton(family, text, raw.baseAddress)
        }
        return parsed == 1 ? buffer : nil
    }
}
