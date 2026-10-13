import Foundation

/// A per-launch capability token standing in for a real secret in the cage:
/// `<prefix>rvph_<32 lowercase hex>`. Worthless outside the minting gateway.
public struct SecretPlaceholder: Sendable, Hashable {
    public static let marker = Array("rvph_".utf8)
    public static let tokenLength = 32

    /// The 32 hex digits; registry key.
    public let token: String
    public let prefix: String

    public var text: String { prefix + "rvph_" + token }

    init(token: String, prefix: String) {
        self.token = token
        self.prefix = prefix
    }

    public static func mint(prefix: String) -> SecretPlaceholder {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        return SecretPlaceholder(token: token, prefix: prefix)
    }

    /// Every `rvph_<32 hex>` occurrence: (marker start, token).
    static func occurrences(in bytes: [UInt8]) -> [(start: Int, token: String)] {
        var found: [(Int, String)] = []
        guard bytes.count >= marker.count + tokenLength else { return [] }
        var index = 0
        while index <= bytes.count - marker.count - tokenLength {
            if bytes[index] == marker[0], Array(bytes[index..<index + marker.count]) == marker {
                let tokenStart = index + marker.count
                let token = bytes[tokenStart..<tokenStart + tokenLength]
                if token.allSatisfy(isLowerHex) {
                    found.append((index, String(decoding: token, as: UTF8.self)))
                    index = tokenStart + tokenLength
                    continue
                }
            }
            index += 1
        }
        return found
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

/// Parsed HTTP/1.1 request head.
struct GatewayRequestHead: Equatable {
    static let maximumBytes = 64 * 1024
    static let maximumHeaders = 128

    var method: String
    var target: String
    var headers: [(name: String, value: String)]

    static func == (lhs: GatewayRequestHead, rhs: GatewayRequestHead) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target
            && lhs.headers.map(\.name) == rhs.headers.map(\.name)
            && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Bytes up to and excluding the blank line. Nil for anything malformed.
    static func parse(_ bytes: [UInt8]) -> GatewayRequestHead? {
        guard bytes.count <= maximumBytes, bytes.contains(0) == false,
            let text = String(bytes: bytes, encoding: .utf8)
        else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, lines.allSatisfy({ $0.contains("\n") == false && $0.contains("\r") == false })
        else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
            parts[0].isEmpty == false, parts[0].utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }),
            parts[1].hasPrefix("/")
        else { return nil }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard line.isEmpty == false, line.first != " ", line.first != "\t",
                let colon = line.firstIndex(of: ":")
            else { return nil }
            let name = String(line[..<colon])
            guard name.isEmpty == false, name.utf8.allSatisfy(isTokenByte) else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append((name, value))
        }
        guard headers.count <= maximumHeaders else { return nil }
        return GatewayRequestHead(method: String(parts[0]), target: String(parts[1]), headers: headers)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}

/// `/s/<NAME>[/rest][?query]` → secret name and the upstream-relative remainder.
struct GatewayRoute: Equatable {
    var secret: String
    var remainder: String

    init?(target: String) {
        guard target.hasPrefix("/s/") else { return nil }
        let afterPrefix = target.dropFirst(3)
        let nameEnd = afterPrefix.firstIndex { $0 == "/" || $0 == "?" } ?? afterPrefix.endIndex
        let name = String(afterPrefix[..<nameEnd])
        guard SecretsDecoding.variable(name) else { return nil }
        let rest = String(afterPrefix[nameEnd...])
        guard rest.contains("#") == false, rest.split(separator: "/").contains("..") == false else { return nil }
        secret = name
        remainder = rest
    }

    /// Upstream URL: the binding's base plus the remainder (path and query).
    func upstreamURL(base: URL) -> URL? {
        var root = base.absoluteString
        if remainder.hasPrefix("/"), root.hasSuffix("/") { root.removeLast() }
        let joined = root + remainder
        guard let url = URL(string: joined), url.host == base.host, url.scheme == "https" else { return nil }
        return url
    }
}

enum GatewayRefusal: Error, Equatable {
    case malformed
    case unknownRoute
    case noPlaceholder
    case unknownPlaceholder
    case foreignPlaceholder
    case tooLarge

    var status: Int {
        switch self {
        case .malformed: 400
        case .unknownRoute: 404
        case .noPlaceholder: 401
        case .unknownPlaceholder, .foreignPlaceholder: 403
        case .tooLarge: 413
        }
    }

    var reason: String {
        switch self {
        case .malformed: "malformed request"
        case .unknownRoute: "no secret is bound to this gateway path"
        case .noPlaceholder: "request carries no rv placeholder for this secret"
        case .unknownPlaceholder: "placeholder is not live in this workspace"
        case .foreignPlaceholder: "placeholder belongs to a different secret"
        case .tooLarge: "request too large"
        }
    }
}

/// Swaps this secret's placeholders for its real value in the target and
/// header values. Body bytes pass through untouched.
enum GatewaySubstitution {
    struct Live {
        var token: String
        var secret: String
        var prefix: String
        var value: SecretValue
    }

    static func apply(
        _ head: GatewayRequestHead,
        route: GatewayRoute,
        lookup: (String) -> Live?
    ) -> Result<(head: GatewayRequestHead, used: Live), GatewayRefusal> {
        var used: Live?
        func rewrite(_ text: String) -> Result<String, GatewayRefusal> {
            let bytes = Array(text.utf8)
            let found = SecretPlaceholder.occurrences(in: bytes)
            guard found.isEmpty == false else { return .success(text) }
            var output: [UInt8] = []
            var cursor = 0
            for occurrence in found {
                guard let live = lookup(occurrence.token) else { return .failure(.unknownPlaceholder) }
                guard live.secret == route.secret else { return .failure(.foreignPlaceholder) }
                let prefix = Array(live.prefix.utf8)
                var start = occurrence.start
                if prefix.isEmpty == false, start >= prefix.count,
                    Array(bytes[(start - prefix.count)..<start]) == prefix, start - prefix.count >= cursor
                {
                    start -= prefix.count
                }
                output += bytes[cursor..<start]
                output += live.value.bytes
                cursor = occurrence.start + SecretPlaceholder.marker.count + SecretPlaceholder.tokenLength
                used = live
            }
            output += bytes[cursor...]
            return .success(String(decoding: output, as: UTF8.self))
        }
        var rewritten = head
        switch rewrite(head.target) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let target): rewritten.target = target
        }
        for index in rewritten.headers.indices {
            switch rewrite(rewritten.headers[index].value) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let value): rewritten.headers[index].value = value
            }
        }
        guard let used else { return .failure(.noPlaceholder) }
        return .success((rewritten, used))
    }
}

/// Streaming replace of real values with their placeholders. Holds back at
/// most `longest - 1` bytes so a value split across chunks is still caught.
struct SecretScrubber {
    private let pairs: [(needle: [UInt8], replacement: [UInt8])]
    private let keep: Int
    private var pending: [UInt8] = []

    init(_ pairs: [(needle: [UInt8], replacement: [UInt8])]) {
        self.pairs = pairs.filter { $0.needle.isEmpty == false }.sorted { $0.needle.count > $1.needle.count }
        keep = max(0, (self.pairs.first?.needle.count ?? 1) - 1)
    }

    mutating func process(_ chunk: [UInt8]) -> [UInt8] {
        pending += chunk
        return drain(final: false)
    }

    mutating func finish() -> [UInt8] {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> [UInt8] {
        guard pairs.isEmpty == false else {
            defer { pending.removeAll() }
            return pending
        }
        var output: [UInt8] = []
        output.reserveCapacity(pending.count)
        var index = 0
        scan: while index < pending.count {
            for pair in pairs where pending.count - index >= pair.needle.count {
                if pending[index] == pair.needle[0],
                    pending[index..<index + pair.needle.count].elementsEqual(pair.needle)
                {
                    output += pair.replacement
                    index += pair.needle.count
                    continue scan
                }
            }
            if final == false, pending.count - index <= keep { break }
            output.append(pending[index])
            index += 1
        }
        pending.removeFirst(index)
        return output
    }

    static func scrub(_ text: String, _ pairs: [(needle: [UInt8], replacement: [UInt8])]) -> String {
        var scrubber = SecretScrubber(pairs)
        let bytes = scrubber.process(Array(text.utf8)) + scrubber.finish()
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum GatewayHeaders {
    /// RFC 9110 hop-by-hop plus framing headers the gateway re-derives.
    static let dropOnRequest: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate",
        "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length", "expect",
        "accept-encoding",
    ]
    static let dropOnResponse: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "te", "trailer",
        "transfer-encoding", "upgrade", "content-length", "content-encoding",
    ]
}
