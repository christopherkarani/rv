import Testing
@testable import RVDomain

/// Owner-set `allowed_ips`: strict CIDR parsing, coverage, the ranges no
/// list may open, and IPv4-mapped IPv6 folding.
@Suite struct EgressAllowedIPsTests {
    // MARK: Parse

    @Test(arguments: [
        ("10.0.5.0/24", "10.0.5.0/24"),
        ("10.0.5.20", "10.0.5.20/32"),
        ("192.168.0.0/16", "192.168.0.0/16"),
        ("172.16.0.0/12", "172.16.0.0/12"),
        ("100.64.0.0/11", "100.64.0.0/11"),
        ("fd12:3456:789a::/48", "fd12:3456:789a::/48"),
        ("FD12:3456:789A::1", "fd12:3456:789a::1/128"),
        // IPv4-mapped IPv6 folds to the IPv4 network it names.
        ("::ffff:10.0.5.0/120", "10.0.5.0/24"),
        ("::ffff:10.0.5.20", "10.0.5.20/32"),
        ("::ffff:a00:0/104", "10.0.0.0/8"),
    ])
    func parsesCanonicalNetworks(_ entry: (String, String)) throws {
        let cidr = try EgressCIDR(parsing: entry.0)
        #expect(cidr.description == entry.1)
    }

    @Test(arguments: [
        "", " 10.0.0.0/8", "10.0.0.0/8 ", "10.0.0.0/", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/08",
        "10.0.0.0/8/8", "10.0.0/24", "10.0.0.0.0/24", "010.0.0.0/8", "10.0.0.256/32", "0x0a.0.0.0/8",
        "10.0.0.0/+8", "fd00::/129", "fd00::/0128", "[fd00::1]", "[fd00::]/64", "fd00:::1/128",
        "staging.lan", "10.0.0.0-10.0.0.255", "*", "10.0.0.*", "::ffff:010.0.0.1",
    ])
    func refusesMalformedEntries(_ entry: String) {
        #expect(throws: EgressAllowedIPError.self) { try EgressCIDR(parsing: entry) }
    }

    @Test(arguments: ["fd00::1%en0", "fd00::/64%1", "fe80::1%lo0"])
    func refusesScopedEntries(_ entry: String) throws {
        let error = try #require(throws: EgressAllowedIPError.self) { try EgressCIDR(parsing: entry) }
        guard case .scopedAddress = error else {
            Issue.record("expected scopedAddress, got \(error)")
            return
        }
    }

    @Test func refusesHostBitsAndNamesTheNetwork() throws {
        let error = try #require(throws: EgressAllowedIPError.self) { try EgressCIDR(parsing: "10.0.5.20/24") }
        #expect(error == .hostBitsSet(entry: "10.0.5.20/24", network: "10.0.5.0/24"))
        #expect(error.message.contains("10.0.5.0/24"))
        #expect(error.message.contains("10.0.5.20/32"))
    }

    /// Mapped IPv6 shorter than /96 reaches outside the mapped block, and
    /// a wider IPv6 network spanning it would never match a folded
    /// address; the owner writes the IPv4 network instead.
    @Test func refusesMappedPrefixShorterThanTheMappedBlock() throws {
        #expect(throws: EgressAllowedIPError.malformed("::ffff:0:0/95")) { try EgressCIDR(parsing: "::ffff:0:0/95") }
        let error = try #require(throws: EgressAllowedIPError.self) { try EgressAllowedIPs(parsing: ["::fffe:0:0/95"]) }
        #expect(error == .forbidden(entry: "::fffe:0:0/95", range: "::ffff:0:0/96", reason: "IPv4-mapped; list the IPv4 network"))
    }

    @Test func listRefusesEmptyOversizedAndAnyBadEntry() {
        #expect(throws: EgressAllowedIPError.empty) { try EgressAllowedIPs(parsing: []) }
        let many = (0..<(EgressAllowedIPs.maximumEntries + 1)).map { "10.0.\($0).0/24" }
        #expect(throws: EgressAllowedIPError.tooMany(limit: EgressAllowedIPs.maximumEntries)) {
            try EgressAllowedIPs(parsing: many)
        }
        // One bad entry refuses the whole list: nothing is silently dropped.
        #expect(throws: EgressAllowedIPError.self) {
            try EgressAllowedIPs(parsing: ["10.0.5.0/24", "10.0.6.0/33"])
        }
    }

    @Test func listIsSortedAndDeduplicated() throws {
        let list = try EgressAllowedIPs(parsing: ["fd12::/48", "10.0.6.0/24", "10.0.5.0/24", "::ffff:10.0.5.0/120"])
        #expect(list.entries == ["10.0.5.0/24", "10.0.6.0/24", "fd12::/48"])
    }

    // MARK: Forbidden ranges

    /// The forbidden table is built by parsing; a typo must not drop a row.
    @Test func everyForbiddenRangeParses() {
        #expect(EgressAllowedIPs.forbiddenRanges.count == 16)
        #expect(EgressAllowedIPs.forbiddenRanges.contains { $0.network.description == "fd00:ec2::254/128" })
        #expect(EgressAllowedIPs.forbiddenRanges.allSatisfy { $0.network.prefixLength > 0 })
    }

    /// Loopback, link-local, cloud metadata, unspecified, multicast, and the
    /// IPv6 forms that embed an IPv4 peer are refused at parse time even
    /// when listed, including a wide network that merely contains one.
    @Test(arguments: [
        "127.0.0.1", "127.0.0.0/8", "126.0.0.0/7", "169.254.169.254", "169.254.0.0/16", "169.0.0.0/8",
        "100.100.100.200", "100.64.0.0/10", "168.63.129.16", "168.63.0.0/16", "0.0.0.0/0", "0.0.0.0",
        "0.0.0.0/8", "224.0.0.1", "239.0.0.0/8", "255.255.255.255", "240.0.0.0/4",
        "::1", "::", "::/0", "::/96", "fe80::1", "fe80::/10", "fec0::/10", "ff02::1", "fd00:ec2::254",
        "fd00::/8", "fd00:ec2::/32", "64:ff9b::a9fe:a9fe", "64:ff9b::/96", "2002:a9fe:a9fe::/48",
        "2001::/32", "::ffff:0:0:0/96", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:7f00:0/104",
        "::a9fe:a9fe",
    ])
    func refusesForbiddenRangesAtParseTime(_ entry: String) throws {
        let error = try #require(throws: EgressAllowedIPError.self) { try EgressAllowedIPs(parsing: [entry]) }
        guard case .forbidden(let named, let range, _) = error else {
            Issue.record("expected forbidden, got \(error)")
            return
        }
        #expect(named == entry)
        #expect(range.isEmpty == false)
        #expect(error.message.contains(entry))
    }

    @Test(arguments: [
        "127.0.0.1", "127.255.255.254", "169.254.169.254", "169.254.0.1", "100.100.100.200", "168.63.129.16",
        "0.0.0.0", "224.0.0.251", "255.255.255.255", "::1", "::", "fe80::1", "ff02::fb", "fd00:ec2::254",
        "::ffff:127.0.0.1", "::ffff:169.254.169.254", "64:ff9b::a9fe:a9fe", "2002:a9fe:a9fe::1",
        "2001:0:a9fe:a9fe::1", "::a9fe:a9fe", "::ffff:0:a9fe:a9fe",
    ])
    func runtimeCheckForbidsTheSameAddresses(_ text: String) throws {
        let address = try #require(EgressIPAddress(parsing: text))
        #expect(EgressAllowedIPs.isForbidden(address))
    }

    // MARK: Coverage

    @Test func coversAddressesInsideTheListOnly() throws {
        let list = try EgressAllowedIPs(parsing: ["10.0.5.0/24", "fd12:3456:789a::/48"])
        for inside in ["10.0.5.0", "10.0.5.20", "10.0.5.255", "fd12:3456:789a::1", "fd12:3456:789a:ffff::9"] {
            #expect(list.covers(try #require(EgressIPAddress(parsing: inside))), "\(inside)")
        }
        for outside in ["10.0.4.255", "10.0.6.0", "10.1.5.20", "192.168.0.1", "8.8.8.8", "fd12:3456:789b::1"] {
            #expect(list.covers(try #require(EgressIPAddress(parsing: outside))) == false, "\(outside)")
        }
    }

    /// `::ffff:10.0.5.20` is the IPv4 host 10.0.5.20 and is judged by the
    /// IPv4 list; an IPv4 list never matches a native IPv6 address.
    @Test func mappedIPv6IsJudgedAsItsIPv4Address() throws {
        let list = try EgressAllowedIPs(parsing: ["10.0.5.0/24"])
        let mapped = try #require(EgressIPAddress(parsing: "::ffff:10.0.5.20"))
        #expect(mapped.family == .ipv4)
        #expect(mapped.description == "10.0.5.20")
        #expect(list.covers(mapped))
        #expect(list.covers(try #require(EgressIPAddress(parsing: "::ffff:10.0.6.1"))) == false)
        #expect(list.covers(try #require(EgressIPAddress(parsing: "::a00:514"))) == false)
        let fromBytes = try #require(EgressIPAddress(ipv6: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 10, 0, 5, 20]))
        #expect(fromBytes == EgressIPAddress(ipv4: [10, 0, 5, 20]))
    }

    @Test func addressInitializersRefuseWrongLengthsAndScopes() {
        #expect(EgressIPAddress(ipv4: [10, 0, 0]) == nil)
        #expect(EgressIPAddress(ipv6: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(EgressIPAddress(parsing: "fd00::1%en0") == nil)
        #expect(EgressIPAddress(parsing: "10.0.0.1/32") == nil)
    }

    @Test func overlapIsSymmetric() throws {
        let wide = try EgressCIDR(parsing: "10.0.0.0/8")
        let narrow = try EgressCIDR(parsing: "10.0.5.0/24")
        let other = try EgressCIDR(parsing: "192.168.0.0/16")
        let v6 = try EgressCIDR(parsing: "fd12::/16")
        #expect(wide.overlaps(narrow) && narrow.overlaps(wide))
        #expect(wide.overlaps(other) == false && other.overlaps(wide) == false)
        #expect(wide.overlaps(v6) == false)
    }

    // MARK: Host policy

    @Test func hostPolicyKeepsRangesOnlyForAllowlistedHosts() throws {
        let list = try EgressAllowedIPs(parsing: ["10.0.5.0/24"])
        let policy = EgressHostPolicy(
            allowedHosts: ["staging.corp.lan"],
            allowedIPs: ["STAGING.corp.lan.": list, "other.corp.lan": list],
            relaysLoopback: false
        )
        #expect(policy.allowedIPs(forHost: "staging.corp.lan") == list)
        #expect(policy.allowedIPs(forHost: "Staging.Corp.Lan.") == list)
        #expect(policy.allowedIPs(forHost: "other.corp.lan") == nil)
        #expect(policy.allowedIPs.keys.sorted() == ["staging.corp.lan"])
        // Generic public mode has no declared endpoints, so no ranges.
        let open = EgressHostPolicy(allowedHosts: [], allowedIPs: ["staging.corp.lan": list], mode: .publicHTTPS)
        #expect(open.allowedIPs.isEmpty)
        #expect(EgressHostPolicy.publicHTTPS.allowedIPs.isEmpty)
    }

    /// Two spellings of one host with different lists are ambiguous: the
    /// host keeps no range rather than the union.
    @Test func hostPolicyDropsAmbiguousDuplicateKeys() throws {
        let first = try EgressAllowedIPs(parsing: ["10.0.5.0/24"])
        let second = try EgressAllowedIPs(parsing: ["10.0.6.0/24"])
        let policy = EgressHostPolicy(
            allowedHosts: ["db.corp.lan"], allowedIPs: ["db.corp.lan": first, "DB.corp.lan": second]
        )
        #expect(policy.allowedIPs(forHost: "db.corp.lan") == nil)
    }
}
