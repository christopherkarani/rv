#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One IP address as network-order bytes.
///
/// IPv4-mapped IPv6 (`::ffff:a.b.c.d`) folds to the IPv4 address it names,
/// so one list judges both spellings of the same host and a mapped
/// loopback or metadata address meets the IPv4 forbidden ranges. No other
/// IPv6 form folds: NAT64, 6to4, Teredo, compatible and translated
/// addresses stay IPv6 and sit inside forbidden ranges instead.
public struct EgressIPAddress: Sendable, Hashable, Comparable, CustomStringConvertible {
    public enum Family: Int, Sendable, Hashable {
        case ipv4 = 4
        case ipv6 = 6
    }

    public let family: Family
    public let bytes: [UInt8]

    public init?(ipv4 bytes: [UInt8]) {
        guard bytes.count == 4 else { return nil }
        family = .ipv4
        self.bytes = bytes
    }

    public init?(ipv6 bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        if Self.isMapped(bytes) {
            family = .ipv4
            self.bytes = Array(bytes[12..<16])
        } else {
            family = .ipv6
            self.bytes = bytes
        }
    }

    /// Strict literal: a dotted quad without leading zeros, or an RFC 4291
    /// IPv6 literal whose IPv4 tail obeys the same rule. Brackets, zones,
    /// prefixes and whitespace are refused.
    public init?(parsing text: String) {
        if let v4 = egressStrictIPv4(text) {
            self.init(ipv4: v4)
        } else if let v6 = egressStrictIPv6(text) {
            self.init(ipv6: v6)
        } else {
            return nil
        }
    }

    public var description: String {
        switch family {
        case .ipv4:
            return bytes.map(String.init).joined(separator: ".")
        case .ipv6:
            return egressPresentIPv6(bytes)
        }
    }

    public static func < (lhs: EgressIPAddress, rhs: EgressIPAddress) -> Bool {
        if lhs.family != rhs.family { return lhs.family.rawValue < rhs.family.rawValue }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    static func isMapped(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
    }
}

/// Why an `allowed_ips` entry or list was refused. Any one refusal
/// refuses the whole configuration that carried it.
public enum EgressAllowedIPError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)
    case scopedAddress(String)
    case hostBitsSet(entry: String, network: String)
    case forbidden(entry: String, range: String, reason: String)
    case empty
    case tooMany(limit: Int)

    public var message: String {
        switch self {
        case .malformed(let entry):
            return "\(entry) is not an IP address or CIDR network (e.g. 10.0.5.0/24, 10.0.5.20, fd12:3456::/48)"
        case .scopedAddress(let entry):
            return "\(entry) has a zone or scope; list the network without %zone"
        case .hostBitsSet(let entry, let network):
            let host = entry.split(separator: "/").first.map(String.init) ?? entry
            let width = host.contains(":") ? 128 : 32
            return "\(entry) has host bits set; write \(network) for the network or \(host)/\(width) for one host"
        case .forbidden(let entry, let range, let reason):
            return "\(entry) reaches \(range) (\(reason)), which rv never relays even when listed"
        case .empty:
            return "must list at least one IP address or CIDR network"
        case .tooMany(let limit):
            return "lists more than \(limit) networks"
        }
    }

    public var description: String { message }
}

/// One IP network: a masked network address plus a prefix length.
public struct EgressCIDR: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let network: EgressIPAddress
    public let prefixLength: Int

    /// Strict `address/prefix` or a bare address (one host). Refuses
    /// malformed text, zones, host bits outside the prefix, and an
    /// IPv4-mapped network shorter than the mapped block. Forbidden ranges
    /// are the list's check (`EgressAllowedIPs`), so this parses them.
    public init(parsing text: String) throws(EgressAllowedIPError) {
        guard text.contains("%") == false else { throw .scopedAddress(text) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { throw .malformed(text) }
        let addressText = String(parts[0])
        let raw: [UInt8]
        if let v4 = egressStrictIPv4(addressText) {
            raw = v4
        } else if let v6 = egressStrictIPv6(addressText) {
            raw = v6
        } else {
            throw .malformed(text)
        }
        let width = raw.count * 8
        var prefix = width
        if parts.count == 2 {
            guard let parsed = egressStrictPrefix(parts[1]), parsed <= width else { throw .malformed(text) }
            prefix = parsed
        }
        var bytes = raw
        if raw.count == 16, EgressIPAddress.isMapped(raw) {
            // `::ffff:a.b.c.d/p` names the IPv4 network a.b.c.d/(p-96); a
            // shorter prefix reaches native IPv6 space outside the block.
            guard prefix >= 96 else { throw .malformed(text) }
            bytes = Array(raw[12..<16])
            prefix -= 96
        }
        let masked = egressMask(bytes, prefix: prefix)
        guard let network = bytes.count == 4 ? EgressIPAddress(ipv4: masked) : EgressIPAddress(ipv6: masked) else {
            throw .malformed(text)
        }
        guard masked == bytes else {
            // At /0 the only network is 0.0.0.0/0 or ::/0, itself
            // forbidden, so suggesting it would mislead.
            guard prefix > 0 else { throw .malformed(text) }
            throw .hostBitsSet(entry: text, network: "\(network)/\(prefix)")
        }
        self.network = network
        self.prefixLength = prefix
    }

    public func contains(_ address: EgressIPAddress) -> Bool {
        address.family == network.family && egressMask(address.bytes, prefix: prefixLength) == network.bytes
    }

    /// True when the two networks share any address: the wider one
    /// contains the narrower one's network address.
    public func overlaps(_ other: EgressCIDR) -> Bool {
        guard network.family == other.network.family else { return false }
        let shorter = min(prefixLength, other.prefixLength)
        return egressMask(network.bytes, prefix: shorter) == egressMask(other.network.bytes, prefix: shorter)
    }

    public var description: String { "\(network)/\(prefixLength)" }

    public static func < (lhs: EgressCIDR, rhs: EgressCIDR) -> Bool {
        if lhs.network != rhs.network { return lhs.network < rhs.network }
        return lhs.prefixLength < rhs.prefixLength
    }
}

/// Owner-set private networks one egress endpoint may reach.
///
/// The proxy relays public unicast only. An endpoint that lists
/// `allowed_ips` may also reach non-public addresses, but only when every
/// address its name resolves to is covered by the list (a mixed answer
/// with one uncovered address is refused whole). The ranges below never
/// open: an entry that touches one is refused at parse time, and
/// `covers` checks the resolved address against them again at dial time.
/// The only way to build a list is `init(parsing:)`, so a list never holds
/// a forbidden or malformed entry.
public struct EgressAllowedIPs: Sendable, Hashable {
    public static let maximumEntries = 32

    /// Sorted and deduplicated.
    public let networks: [EgressCIDR]

    public init(parsing entries: [String]) throws(EgressAllowedIPError) {
        guard entries.isEmpty == false else { throw .empty }
        guard entries.count <= Self.maximumEntries else { throw .tooMany(limit: Self.maximumEntries) }
        var parsed = Set<EgressCIDR>()
        for entry in entries {
            let cidr = try EgressCIDR(parsing: entry)
            if let blocked = Self.forbiddenRanges.first(where: { $0.network.overlaps(cidr) }) {
                throw .forbidden(entry: entry, range: blocked.network.description, reason: blocked.reason)
            }
            if Self.spansMappedBlock(cidr) {
                throw .forbidden(entry: entry, range: "::ffff:0:0/96", reason: "IPv4-mapped; list the IPv4 network")
            }
            parsed.insert(cidr)
        }
        networks = parsed.sorted()
    }

    /// Canonical spellings, for listings, reviews and risk reports.
    public var entries: [String] { networks.map(\.description) }

    /// True when `address` is inside the list and outside every forbidden
    /// range (the runtime half of the parse-time refusal).
    public func covers(_ address: EgressIPAddress) -> Bool {
        guard Self.isForbidden(address) == false else { return false }
        return networks.contains { $0.contains(address) }
    }

    public static func isForbidden(_ address: EgressIPAddress) -> Bool {
        forbiddenRanges.contains { $0.network.contains(address) }
    }

    /// An IPv6 network of /96 or wider whose prefix matches `::ffff:0:0/96`.
    /// (Narrower mapped networks already folded to IPv4 in `EgressCIDR`.)
    static func spansMappedBlock(_ cidr: EgressCIDR) -> Bool {
        guard cidr.network.family == .ipv6, cidr.prefixLength <= 96 else { return false }
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0]
        return egressMask(cidr.network.bytes, prefix: cidr.prefixLength) == egressMask(mapped, prefix: cidr.prefixLength)
    }

    struct ForbiddenRange: Sendable {
        var network: EgressCIDR
        var reason: String
    }

    /// Never relayed, listed or not. The IPv6 transition forms (compatible,
    /// translated, NAT64, Teredo, 6to4) embed an IPv4 peer the host may
    /// dial, so they are refused whole; list the IPv4 network instead.
    /// Mapped addresses fold to IPv4 and meet the IPv4 ranges. The mapped
    /// block cannot be listed here (`EgressCIDR` folds it to 0.0.0.0/0), so
    /// `spansMappedBlock` refuses a wider IPv6 network that covers it,
    /// which would otherwise sit silently inert.
    ///
    /// The IPv4 blocks `EgressWire.isPublicIPv4` refuses as never a LAN
    /// service are here too: 192.0.0.0/24 (IETF protocol assignments, and
    /// Oracle's legacy metadata 192.0.0.192), the 6to4 relay anycast,
    /// documentation and benchmarking; so are the IPv6 documentation and
    /// IETF-assignment blocks. Not every block `isPublicIPv6` refuses is
    /// listed: unallocated space such as 4000::/2, the 100::/64 discard
    /// prefix and 5f00::/16 SRv6 SIDs stay listable, which is harmless
    /// (nothing answers there). AWS's IPv6 platform hosts (metadata, DNS,
    /// time) are refused one by one, so the rest of ULA stays listable.
    static let forbiddenRanges: [ForbiddenRange] = ([
        ("0.0.0.0/8", "unspecified"),
        ("127.0.0.0/8", "loopback"),
        ("169.254.0.0/16", "link-local and cloud metadata"),
        ("100.100.100.200/32", "cloud metadata"),
        ("168.63.129.16/32", "cloud platform endpoint"),
        ("192.0.0.0/24", "IETF protocol assignments and cloud metadata"),
        ("192.88.99.0/24", "6to4 relay anycast"),
        ("192.0.2.0/24", "documentation"),
        ("198.51.100.0/24", "documentation"),
        ("203.0.113.0/24", "documentation"),
        ("198.18.0.0/15", "benchmarking"),
        ("224.0.0.0/4", "multicast"),
        ("240.0.0.0/4", "reserved and broadcast"),
        ("::/96", "unspecified, loopback and IPv4-compatible"),
        ("::ffff:0:0:0/96", "IPv4-translated"),
        ("64:ff9b::/32", "NAT64"),
        ("2001::/32", "Teredo"),
        ("2001::/23", "IETF protocol assignments and benchmarking"),
        ("2001:db8::/32", "documentation"),
        ("3fff::/20", "documentation"),
        ("2002::/16", "6to4"),
        ("fe80::/10", "link-local"),
        ("fec0::/10", "site-local"),
        ("ff00::/8", "multicast"),
        ("fd00:ec2::254/128", "cloud metadata"),
        ("fd00:ec2::253/128", "cloud DNS resolver"),
        ("fd00:ec2::123/128", "cloud time service"),
        ("fd20:ce::254/128", "cloud metadata"),
    ] as [(String, String)]).compactMap { text, reason in
        (try? EgressCIDR(parsing: text)).map { ForbiddenRange(network: $0, reason: reason) }
    }
}

private func egressMask(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
    bytes.enumerated().map { index, byte in
        let bits = min(max(prefix - index * 8, 0), 8)
        let mask: UInt8 = bits == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        return byte & mask
    }
}

/// Decimal prefix length, no sign, no leading zero (except `0`).
private func egressStrictPrefix(_ text: Substring) -> Int? {
    guard (1...3).contains(text.count), text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    if text.count > 1, text.hasPrefix("0") { return nil }
    return Int(text)
}

/// Dotted quad, four decimal parts 0-255, no leading zeros: a resolver
/// reads `010` as octal, so a leading zero is refused rather than guessed.
private func egressStrictIPv4(_ text: String) -> [UInt8]? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var bytes: [UInt8] = []
    for part in parts {
        guard (1...3).contains(part.count), part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if part.count > 1, part.hasPrefix("0") { return nil }
        guard let value = UInt8(part) else { return nil }
        bytes.append(value)
    }
    return bytes
}

private func egressStrictIPv6(_ text: String) -> [UInt8]? {
    guard text.contains(":"), text.utf8.count <= 45 else { return nil }
    guard text.utf8.allSatisfy({ byte in
        (byte >= 48 && byte <= 58) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102) || byte == 46
    }) else { return nil }
    if text.contains(".") {
        guard let tail = text.split(separator: ":", omittingEmptySubsequences: false).last,
            egressStrictIPv4(String(tail)) != nil
        else { return nil }
    }
    var address = in6_addr()
    let parsed = text.withCString { inet_pton(AF_INET6, $0, &address) }
    guard parsed == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
}

/// RFC 5952 text, the same on every platform (`inet_ntop` spells embedded
/// IPv4 forms differently on Darwin and glibc): lowercase hex groups, the
/// first longest run of two or more zero groups as `::`, no dotted tail.
private func egressPresentIPv6(_ bytes: [UInt8]) -> String {
    let groups = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
    var best = (start: -1, length: 0)
    var index = 0
    while index < groups.count {
        guard groups[index] == 0 else {
            index += 1
            continue
        }
        let start = index
        while index < groups.count, groups[index] == 0 { index += 1 }
        if index - start > best.length { best = (start, index - start) }
    }
    let hex = groups.map { String($0, radix: 16) }
    guard best.length >= 2 else { return hex.joined(separator: ":") }
    let head = hex[..<best.start].joined(separator: ":")
    let tail = hex[(best.start + best.length)...].joined(separator: ":")
    return head + "::" + tail
}
