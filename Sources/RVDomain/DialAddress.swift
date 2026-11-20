/// May this IP address be dialed on an agent's behalf?
///
/// One range table answers for every door that dials: the egress proxy,
/// the admission GET, and the `allowed_ips` parser. Each range carries its
/// judgment and the reason an owner is shown. An address takes the
/// strictest judgment of every range that holds it, and an address no
/// range holds is public unicast, so a narrower range can only tighten a
/// wider one and the order of rows never widens what may be dialed.
///
/// The table reads an address literally: the IPv6 forms that embed an
/// IPv4 address (mapped, translated, compatible, NAT64, 6to4) sit inside
/// `never` ranges. `judgment(followingEmbeddedIPv4:)` judges the IPv4 a
/// dial to such a form reaches instead. Which of the two a door asks, and
/// what it does with the answer (every DNS answer must agree, an owner
/// list may widen what is admitted), is that door's policy.
package enum DialJudgment: Int, Sendable, Comparable {
    /// Globally routable unicast. Any door may dial it.
    case publicUnicast
    /// Not public, but an owner's `allowed_ips` may open it: private
    /// networks, shared address space, unique local, unallocated IPv6.
    case listablePrivate
    /// Never dialed, listed or not: loopback, link-local, cloud metadata,
    /// multicast, documentation, and the IPv6 forms that embed an IPv4 peer.
    case never

    package static func < (lhs: DialJudgment, rhs: DialJudgment) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One row of the dial-address table: a network, its judgment, and why.
package struct DialRange: Sendable, Hashable, CustomStringConvertible {
    /// Network-order bytes with every host bit clear: 4 for IPv4, 16 for IPv6.
    package let network: [UInt8]
    package let prefixLength: Int
    package let judgment: DialJudgment
    package let reason: String

    package func contains(_ address: [UInt8]) -> Bool {
        address.count == network.count && dialPrefixMatches(address, network, bits: prefixLength)
    }

    /// True when the two networks share any address.
    package func overlaps(network other: [UInt8], prefixLength otherLength: Int) -> Bool {
        other.count == network.count && dialPrefixMatches(other, network, bits: min(prefixLength, otherLength))
    }

    package var description: String {
        let text = network.count == 4 ? network.map(String.init).joined(separator: ".") : egressPresentIPv6(network)
        return "\(text)/\(prefixLength)"
    }
}

package enum DialAddress {
    /// The judgment for a 4- or 16-byte address read literally. Any other
    /// length is `never`.
    package static func judgment(of address: [UInt8]) -> DialJudgment {
        guard address.count == 4 || address.count == 16 else { return .never }
        return range(holding: address)?.judgment ?? .publicUnicast
    }

    /// The judgment for the address a dial reaches: an IPv6 form with a
    /// fixed IPv4 embedding takes that IPv4 address's judgment, everything
    /// else is read literally.
    package static func judgment(followingEmbeddedIPv4 address: [UInt8]) -> DialJudgment {
        judgment(of: embeddedIPv4(of: address) ?? address)
    }

    /// The range that decides `address`: the strictest that holds it, then
    /// the narrowest. Nil when no range holds it (public unicast).
    package static func range(holding address: [UInt8]) -> DialRange? {
        var decided: DialRange?
        for range in ranges where range.contains(address) {
            guard let current = decided else {
                decided = range
                continue
            }
            if range.judgment > current.judgment
                || (range.judgment == current.judgment && range.prefixLength > current.prefixLength)
            {
                decided = range
            }
        }
        return decided
    }

    /// The first `never` range, in table order, that shares any address
    /// with the network.
    package static func neverRange(overlapping network: [UInt8], prefixLength: Int) -> DialRange? {
        ranges.first { $0.judgment == .never && $0.overlaps(network: network, prefixLength: prefixLength) }
    }

    /// The IPv4 address a dial to this IPv6 address reaches, for the forms
    /// whose embedding is fixed: IPv4-mapped `::ffff:0:0/96`,
    /// IPv4-translated `::ffff:0:0:0/96`, IPv4-compatible `::/96` (not
    /// `::` or `::1`), NAT64 `64:ff9b::/96` and 6to4 `2002::/16`. Nil for
    /// everything else, including Teredo and the rest of `64:ff9b::/32`,
    /// whose embedding is obfuscated or chosen by the operator.
    package static func embeddedIPv4(of address: [UInt8]) -> [UInt8]? {
        guard address.count == 16 else { return nil }
        let head = Array(address[0..<12])
        let tail = Array(address[12..<16])
        switch head {
        case [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF], // mapped
            [0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0], // translated (SIIT)
            [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]: // NAT64 well-known prefix
            return tail
        case [UInt8](repeating: 0, count: 12): // compatible
            return tail == [0, 0, 0, 0] || tail == [0, 0, 0, 1] ? nil : tail
        default:
            guard address[0] == 0x20, address[1] == 0x02 else { return nil }
            return Array(address[2..<6]) // 6to4 carries it in bits 16-47
        }
    }

    /// The table. Rows are written as bytes, so none can fail to build.
    /// `allowed_ips` names the first `never` row an entry overlaps, so the
    /// order of rows is the order its refusals are reported in.
    ///
    /// Public-space platform endpoints (Azure WireServer), relay anycast,
    /// documentation and benchmarking are `never`: no LAN service lives
    /// there. Unallocated IPv6 (outside 2000::/3, such as 4000::/2, the
    /// 100::/64 discard prefix and 5f00::/16 SRv6 SIDs) is
    /// `listablePrivate`, which is harmless (nothing answers there). AWS's
    /// and GCP's IPv6 platform hosts are refused one by one so the rest of
    /// unique local stays listable.
    package static let ranges: [DialRange] = [
        v4(0, 0, 0, 0, 8, .never, "unspecified"),
        v4(127, 0, 0, 0, 8, .never, "loopback"),
        v4(10, 0, 0, 0, 8, .listablePrivate, "private network"),
        v4(172, 16, 0, 0, 12, .listablePrivate, "private network"),
        v4(192, 168, 0, 0, 16, .listablePrivate, "private network"),
        v4(100, 64, 0, 0, 10, .listablePrivate, "shared address space"),
        v4(169, 254, 0, 0, 16, .never, "link-local and cloud metadata"),
        v4(100, 100, 100, 200, 32, .never, "cloud metadata"),
        v4(168, 63, 129, 16, 32, .never, "cloud platform endpoint"),
        v4(192, 0, 0, 0, 24, .never, "IETF protocol assignments and cloud metadata"),
        v4(192, 88, 99, 0, 24, .never, "6to4 relay anycast"),
        v4(192, 0, 2, 0, 24, .never, "documentation"),
        v4(198, 51, 100, 0, 24, .never, "documentation"),
        v4(203, 0, 113, 0, 24, .never, "documentation"),
        v4(198, 18, 0, 0, 15, .never, "benchmarking"),
        v4(224, 0, 0, 0, 4, .never, "multicast"),
        v4(240, 0, 0, 0, 4, .never, "reserved and broadcast"),
        // Global unicast is 2000::/3; these three cover the rest.
        v6([0x0000], 3, .listablePrivate, "outside global unicast"),
        v6([0x4000], 2, .listablePrivate, "outside global unicast"),
        v6([0x8000], 1, .listablePrivate, "outside global unicast"),
        v6([0xFC00], 7, .listablePrivate, "unique local"),
        v6([], 96, .never, "unspecified, loopback and IPv4-compatible"),
        v6([0, 0, 0, 0, 0xFFFF], 96, .never, "IPv4-translated"),
        v6([0x64, 0xFF9B], 32, .never, "NAT64"),
        v6([0x2001], 32, .never, "Teredo"),
        v6([0x2001], 23, .never, "IETF protocol assignments and benchmarking"),
        v6([0x2001, 0x0DB8], 32, .never, "documentation"),
        v6([0x3FFF], 20, .never, "documentation"),
        v6([0x2002], 16, .never, "6to4"),
        v6([0xFE80], 10, .never, "link-local"),
        v6([0xFEC0], 10, .never, "site-local"),
        v6([0xFF00], 8, .never, "multicast"),
        v6([0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254], 128, .never, "cloud metadata"),
        v6([0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0253], 128, .never, "cloud DNS resolver"),
        v6([0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0123], 128, .never, "cloud time service"),
        v6([0xFD20, 0x00CE, 0, 0, 0, 0, 0, 0x0254], 128, .never, "cloud metadata"),
        // Last: `allowed_ips` folds a mapped entry to IPv4, so this row
        // only meets an IPv6 network wide enough to span the block.
        v6([0, 0, 0, 0, 0, 0xFFFF], 96, .never, "IPv4-mapped; list the IPv4 network"),
    ]

    private static func v4(
        _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8, _ prefixLength: Int,
        _ judgment: DialJudgment, _ reason: String
    ) -> DialRange {
        DialRange(network: [a, b, c, d], prefixLength: prefixLength, judgment: judgment, reason: reason)
    }

    /// Leading 16-bit groups; the groups not written are zero.
    private static func v6(
        _ groups: [UInt16], _ prefixLength: Int, _ judgment: DialJudgment, _ reason: String
    ) -> DialRange {
        let padded = groups + [UInt16](repeating: 0, count: max(0, 8 - groups.count))
        let bytes = padded.prefix(8).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        return DialRange(network: bytes, prefixLength: prefixLength, judgment: judgment, reason: reason)
    }
}

/// True when the first `bits` bits of the two byte strings agree.
private func dialPrefixMatches(_ left: [UInt8], _ right: [UInt8], bits: Int) -> Bool {
    var remaining = bits
    var index = 0
    while remaining > 0, index < left.count, index < right.count {
        let take = min(remaining, 8)
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - take))
        if left[index] & mask != right[index] & mask { return false }
        remaining -= take
        index += 1
    }
    return true
}
