import Foundation

/// Fixed bounds for the supported HTTPS GET.
///
/// The agent cannot raise these. A response that would pass the body cap is
/// refused before the extra bytes are kept.
public enum HTTPEgressLimits {
    public static let maxResponseBodyBytes = 65_536
    public static let maxHeaderBlockBytes = 16_384
    public static let maxHeaderCount = 64
    public static let maxHeaderValueBytes = 512
    public static let maxURLUTF8Bytes = 2_048
    public static let maxCanonicalUTF8Bytes = 4_096
    public static let requestTimeoutMilliseconds = 10_000
    public static let connectTimeoutMilliseconds = 5_000
    public static let maxRedirects = 0
    public static let readSliceMilliseconds = 50
    public static let userAgent = "rv-http/1"
}

public enum HTTPMethod: String, Sendable, Equatable, Codable {
    case get = "GET"
}

package enum HTTPHostKind: String, Sendable, Equatable, Codable {
    case dns
    case ipv4
    case ipv6
}

public enum HTTPIPFamily: String, Sendable, Equatable, Codable {
    case ipv4
    case ipv6
}

/// Whether the admission GET may dial a destination.
///
/// `publicGlobal` is the only class the executor may dial. An address is
/// judged by the dial-address table (`DialAddress`) read literally, so the
/// IPv6 forms that embed an IPv4 address are never dialed here: the
/// admission GET dials exactly the address it judged.
public enum HTTPAddressClass: String, Sendable, Equatable, Codable {
    case publicGlobal
    /// Inside a range of the dial-address table.
    case nonPublic
    /// A name refused before lookup.
    case localName
    /// No address to judge.
    case unresolved
}

/// One IP address, judged from its bytes.
///
/// Presentation and judgment are derived. A decoded value cannot claim a
/// different judgment than those bytes.
public struct HTTPIPAddress: Hashable, Sendable, Equatable {
    public let family: HTTPIPFamily
    public let presentation: String
    public let bytes: [UInt8]
    package let judgment: DialJudgment

    public var isPublicGlobal: Bool {
        judgment == .publicUnicast
    }

    public init?(ipv4 bytes: [UInt8]) {
        guard bytes.count == 4 else { return nil }
        self.family = .ipv4
        self.bytes = bytes
        self.presentation = "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
        self.judgment = DialAddress.judgment(of: bytes)
    }

    public init?(ipv6 bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.family = .ipv6
        self.bytes = bytes
        self.presentation = HTTPAddressClass.present(ipv6: bytes)
        self.judgment = DialAddress.judgment(of: bytes)
    }
}

extension HTTPIPAddress: Codable {
    private enum CodingKeys: String, CodingKey {
        case bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bytes = try container.decode([UInt8].self, forKey: .bytes)
        if bytes.count == 4, let address = HTTPIPAddress(ipv4: bytes) {
            self = address
            return
        }
        if bytes.count == 16, let address = HTTPIPAddress(ipv6: bytes) {
            self = address
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "IP address length")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bytes, forKey: .bytes)
    }
}

/// Outcome of one name lookup. Any forbidden answer rejects the name.
package enum HTTPAddressSelection: Sendable, Equatable {
    case empty
    case pinned(HTTPIPAddress)
    case forbidden(HTTPIPAddress)
}

/// Picks the address RV will dial, or one forbidden address that blocks the name.
///
/// IPv4 is preferred when every answer is public. A mixed answer is forbidden
/// even when another answer is public.
package func selectHTTPAddresses(_ addresses: [HTTPIPAddress]) -> HTTPAddressSelection {
    var seen = Set<HTTPIPAddress>()
    let unique = addresses.filter { seen.insert($0).inserted }
    let ordered = unique.sorted { left, right in
        if left.family != right.family {
            return left.family == .ipv4
        }
        return left.presentation < right.presentation
    }
    guard let firstForbidden = ordered.first(where: { $0.isPublicGlobal == false }) else {
        guard let pinned = ordered.first else { return .empty }
        return .pinned(pinned)
    }
    return .forbidden(firstForbidden)
}

extension HTTPAddressClass {
    static func present(ipv6 bytes: [UInt8]) -> String {
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return "::ffff:\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
        }
        var groups = [UInt16]()
        groups.reserveCapacity(8)
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append((UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]))
        }
        var bestStart = -1
        var bestLength = 0
        var cursor = 0
        while cursor < 8 {
            if groups[cursor] == 0 {
                let start = cursor
                while cursor < 8 && groups[cursor] == 0 {
                    cursor += 1
                }
                let length = cursor - start
                if length > bestLength {
                    bestStart = start
                    bestLength = length
                }
            } else {
                cursor += 1
            }
        }
        if bestLength < 2 {
            bestStart = -1
        }
        var text = ""
        var index = 0
        while index < 8 {
            if index == bestStart {
                text += "::"
                index += bestLength
                continue
            }
            if text.isEmpty == false && text.hasSuffix("::") == false {
                text += ":"
            }
            text += String(groups[index], radix: 16)
            index += 1
        }
        return text.isEmpty ? "::" : text
    }
}

/// Project-approved SHA-256 over raw bytes, as lowercase hex.
///
/// Pure Swift, cross-platform, no new dependency. This is the same audited
/// core (`RVSHA256Digest`) that `AgentDefinitionRevision` and
/// `WorkspaceLaunchIntent` digest through; cross-module consumers (such as
/// the host-prepared launch environment snapshot) use this entry point
/// instead of inventing a hash scheme.
public enum RVDigest {
    public static func sha256Hex(_ bytes: [UInt8]) -> String {
        sha256(bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var hash = RVSHA256Digest()
        hash.update(bytes)
        return hash.digest()
    }

    /// RFC 2104 HMAC over this SHA-256, so MACs match on every platform.
    public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let blockSize = 64
        var block = key.count > blockSize ? sha256(key) : key
        block += [UInt8](repeating: 0, count: blockSize - block.count)
        let inner = sha256(block.map { $0 ^ 0x36 } + message)
        return sha256(block.map { $0 ^ 0x5c } + inner)
    }

    /// Chunked SHA-256 over file bytes. Nil when the file cannot be read.
    /// `maxBytes` refuses a file that grows past the cap instead of hashing to EOF.
    public static func sha256HexOfFile(atPath path: String, maxBytes: UInt64? = nil) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hash = RVSHA256Digest()
        var total: UInt64 = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return nil
            }
            guard let chunk, chunk.isEmpty == false else { break }
            total += UInt64(chunk.count)
            guard maxBytes.map({ total <= $0 }) ?? true else { return nil }
            hash.update([UInt8](chunk))
        }
        return hash.digest().map { String(format: "%02x", $0) }.joined()
    }
}

enum HTTPDigest {
    static func sha256Hex(_ bytes: [UInt8]) -> String {
        RVDigest.sha256Hex(bytes)
    }
}

/// Incremental SHA-256 over raw bytes. Pure value semantics; the shell
/// (`RVIsolation`'s file digest) drives this over file chunks.
public struct RVSHA256Digest: Sendable {
    public init() {}

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var bitCount: UInt64 = 0

    public mutating func update(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        bitCount &+= UInt64(bytes.count) &* 8
        while buffer.count >= 64 {
            compress(Array(buffer.prefix(64)))
            buffer.removeFirst(64)
        }
    }

    public func digest() -> [UInt8] {
        var copy = self
        let length = copy.bitCount
        copy.buffer.append(0x80)
        while copy.buffer.count % 64 != 56 {
            copy.buffer.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            copy.buffer.append(UInt8((length >> UInt64(shift)) & 0xff))
        }
        while copy.buffer.count >= 64 {
            copy.compress(Array(copy.buffer.prefix(64)))
            copy.buffer.removeFirst(64)
        }
        return copy.state.flatMap { word in
            (0..<4).map { UInt8((word >> UInt32(24 - $0 * 8)) & 0xff) }
        }
    }

    private mutating func compress(_ block: [UInt8]) {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = index * 4
            words[index] = (UInt32(block[base]) << 24) | (UInt32(block[base + 1]) << 16)
                | (UInt32(block[base + 2]) << 8) | UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let s0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
            let s1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }
        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for index in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ choice &+ Self.k[index] &+ words[index]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
