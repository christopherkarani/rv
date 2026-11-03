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

    /// `text` with every placeholder token replaced, for audit records.
    static func redacted(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        var cursor = 0
        for occurrence in occurrences(in: bytes) {
            output += bytes[cursor..<occurrence.start] + Array("rvph_[redacted]".utf8)
            cursor = occurrence.start + marker.count + tokenLength
        }
        return String(decoding: output + bytes[cursor...], as: UTF8.self)
    }

    /// The target's path for audit: no query, placeholders redacted, and
    /// decoded once when that reveals a percent-encoded placeholder.
    static func redactedPath(_ target: String) -> String {
        let path = Array(target.utf8.prefix { $0 != UInt8(ascii: "?") })
        let decoded = GatewaySubstitution.percentDecoded(path)
        let encoded = occurrences(in: decoded).count != occurrences(in: path).count
        return redacted(String(decoding: encoded ? decoded : path, as: UTF8.self))
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

    /// Every value for `name`, in arrival order. `header` is the first one.
    /// Body framing has to see the rest: a later `Content-Length` can disagree
    /// or sit above the maximum.
    func headerValues(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
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

/// How `readBody` frames one request. Two `Content-Length` values that
/// disagree, a value that does not parse, or any value above `maximum`
/// is refused. That includes a later length beside `Transfer-Encoding`.
enum GatewayBodyFraming: Equatable, Sendable {
    case empty
    case fixed(Int)
    case chunked
    case refused
}

func gatewayBodyFraming(
    transferEncodings: [String],
    contentLengths: [String],
    maximum: Int
) -> GatewayBodyFraming {
    if contentLengthsRefuseBody(contentLengths, maximum: maximum) {
        return .refused
    }
    if transferEncodings.isEmpty == false {
        let chunked = transferEncodings.allSatisfy { $0.lowercased() == "chunked" }
        return chunked ? .chunked : .refused
    }
    guard let first = contentLengths.first else { return .empty }
    guard let length = Int(first), length >= 0, length <= maximum else { return .refused }
    return length == 0 ? .empty : .fixed(length)
}

/// True when any length is unusable, above `maximum`, or not the same
/// number as the others. A single in-range length, including zero, is not
/// a refusal. Missing lengths are not a refusal.
func contentLengthsRefuseBody(_ values: [String], maximum: Int) -> Bool {
    if values.isEmpty { return false }
    var accepted: Int?
    for value in values {
        guard let length = Int(value), length >= 0, length <= maximum else { return true }
        if let accepted, accepted != length { return true }
        accepted = length
    }
    return false
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

/// Every raw value is the literal audit/OCSF code: renaming a case cannot change
/// what reaches the log. Raw-value enums cannot carry associated values: a case
/// that needs a payload drops the raw type and makes `code` an exhaustive
/// switch returning the same literals, so no code changes with the payload.
public enum GatewayRefusal: String, Error, Equatable, Sendable, CaseIterable {
    case malformed = "malformed"
    case unknownRoute = "unknownRoute"
    case noPlaceholder = "noPlaceholder"
    case unknownPlaceholder = "unknownPlaceholder"
    case foreignPlaceholder = "foreignPlaceholder"
    case tooLarge = "tooLarge"
    /// The value would change the request's shape where the placeholder sits.
    case unsafeValue = "unsafeValue"
    /// TRACE and TRACK make the upstream echo the request, credential included.
    case echoMethod = "echoMethod"
    /// A percent-encoded placeholder: never swapped, so never forwarded.
    case encodedPlaceholder = "encodedPlaceholder"
    /// The placeholder sits on a surface its binding does not allow.
    case surfaceNotAllowed = "surfaceNotAllowed"
    /// A second placeholder on one surface, e.g. a copy in another header
    /// that the upstream might log or echo.
    case repeatedPlaceholder = "repeatedPlaceholder"
    /// Method or path outside the secret's allow rules.
    case outsideAllowRules = "outsideAllowRules"
    /// With allow rules, a path an upstream could read differently from the
    /// matcher: encoded `/` or dots, `..`, `;`, `//`, or double encoding.
    case ambiguousPath = "ambiguousPath"
    /// The forward record did not reach the audit log.
    case auditUnavailable = "auditUnavailable"
    /// The connection came from outside the runtime the placeholder was leased to.
    case runtimeMismatch = "runtimeMismatch"
    /// The gateway could not tie the connection to the placeholder's runtime.
    case runtimeUnverified = "runtimeUnverified"
    /// The secret's `expires` has passed.
    case expired = "expired"
    /// The refresh interval and its grace have passed without a successful refresh.
    case refreshFailed = "refreshFailed"
    /// A SigV4 request whose access key id is not the secret's placeholder.
    case awsKeyMismatch = "awsKeyMismatch"
    /// A signed-chunk or event-stream payload: each chunk signature chains to
    /// the agent's seed signature, which the gateway replaces.
    case awsSignedStreaming = "awsSignedStreaming"
    /// An `approve` rule holds this request and no human has said yes yet.
    case approvalPending = "approvalPending"
    /// The human denied it, the approval lapsed, or the grant could not be consumed.
    case approvalDenied = "approvalDenied"
    /// No approval service can be asked: no admission channel, no live agent
    /// principal, or the service declined to file it.
    case approvalUnavailable = "approvalUnavailable"
    /// A process holding the connection, and none of its ancestors up to the
    /// runtime's leader, runs a binary the secret's `binaries` list allows.
    case binaryMismatch = "binaryMismatch"
    /// An unsigned-payload mode on a service other than S3, whose signature
    /// the gateway cannot produce for it.
    case awsUnsignedPayload = "awsUnsignedPayload"
    /// The upstream's answer carried a `SecretAccessKey`: credentials minted
    /// by the call, which would otherwise reach the agent unscrubbed.
    case awsCredentialsInResponse = "awsCredentialsInResponse"

    /// Seconds a client should wait before retrying, sent as `Retry-After`.
    var retryAfter: Int? { self == .approvalPending ? 5 : nil }

    /// The stable code for audit records: the explicit raw value.
    var code: String { rawValue }

    /// A request the secret's own policy forbids: worth an alert, since a
    /// well-behaved client using the placeholder as documented never sends one.
    var isMisuse: Bool {
        switch self {
        case .foreignPlaceholder, .surfaceNotAllowed, .repeatedPlaceholder, .outsideAllowRules, .encodedPlaceholder,
            .ambiguousPath, .echoMethod, .runtimeMismatch, .awsKeyMismatch, .binaryMismatch:
            true
        case .malformed, .unknownRoute, .noPlaceholder, .unknownPlaceholder, .tooLarge, .unsafeValue,
            .auditUnavailable, .runtimeUnverified, .expired, .refreshFailed, .awsSignedStreaming, .awsUnsignedPayload,
            .awsCredentialsInResponse, .approvalPending, .approvalDenied, .approvalUnavailable:
            false
        }
    }

    var status: Int {
        switch self {
        case .malformed, .unsafeValue, .encodedPlaceholder, .ambiguousPath, .awsSignedStreaming,
            .awsUnsignedPayload:
            400
        case .auditUnavailable, .refreshFailed: 503
        case .awsCredentialsInResponse: 502
        case .unknownRoute: 404
        case .noPlaceholder: 401
        case .unknownPlaceholder, .foreignPlaceholder, .surfaceNotAllowed, .repeatedPlaceholder, .outsideAllowRules,
            .runtimeMismatch, .runtimeUnverified, .expired, .awsKeyMismatch, .approvalPending, .approvalDenied,
            .approvalUnavailable, .binaryMismatch:
            403
        case .tooLarge: 413
        case .echoMethod: 405
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
        case .unsafeValue: "secret value cannot be placed safely at this placeholder's position"
        case .echoMethod: "method would echo the brokered credential back"
        case .encodedPlaceholder: "placeholder is percent-encoded; send it as-is"
        case .surfaceNotAllowed: "placeholder is not allowed in this part of the request for this secret"
        case .repeatedPlaceholder: "placeholder may appear once per surface (header, query, path)"
        case .outsideAllowRules: "method and path are outside this secret's allow rules"
        case .ambiguousPath: "path has encoded separators, dot segments, or ;; send it plainly"
        case .auditUnavailable: "the audit log could not record this request, so it was not forwarded"
        case .runtimeMismatch: "placeholder was presented from outside the runtime it was issued to"
        case .runtimeUnverified: "the gateway could not confirm this connection comes from the placeholder's runtime"
        case .expired: "the secret has expired; store a new value with `rv secrets set` and a later --expires"
        case .refreshFailed: "the secret could not be refreshed from its provider, so it was not used"
        case .awsKeyMismatch: "the request is signed with an access key other than this secret's AWS_ACCESS_KEY_ID"
        case .awsSignedStreaming:
            "signed streaming payloads cannot be re-signed; send UNSIGNED-PAYLOAD or STREAMING-UNSIGNED-PAYLOAD-TRAILER"
        case .approvalPending:
            "this request needs a human's approval in rv; once approved, retry the identical request"
        case .approvalDenied: "the approval for this request was denied, expired, or already used"
        case .approvalUnavailable:
            "this request needs a human's approval, and no approver is available for this runtime"
        case .binaryMismatch: "this secret may be used only by the binaries its definition lists"
        case .awsUnsignedPayload:
            "unsigned payload modes are accepted for S3 only; send the body with a payload hash for this service"
        case .awsCredentialsInResponse:
            "the AWS response carried new credentials, which are never passed to the agent"
        }
    }
}

/// Swaps this secret's placeholders for its real value in the target and
/// header values. Body bytes pass through untouched. The value is encoded or
/// refused per position so it cannot change the request's shape: a path
/// segment stays one segment, a query value one value, a header one line.
/// A placeholder off its binding's surfaces, or a second one on a surface,
/// is refused before any value is placed, as is a request outside the
/// binding's allow rules.
enum GatewaySubstitution {
    struct Live {
        var token: String
        var secret: String
        var prefix: String
        /// Nil for an entry the gateway signs with, which is never written into a request.
        var value: SecretValue?
        var surfaces: Set<GatewaySurface>
        /// Expanded allow rules; empty allows any method and path.
        var rules: [GatewayAccessRule] = []
        /// The upstream URL's own path, which rules match in front of the route's.
        var basePath = ""
    }

    /// Where a placeholder sits in the request head.
    enum Position {
        case path
        case query
        case header
        /// The user half of decoded Basic credentials, where `:` would move the split.
        case basicUser

        var surface: GatewaySurface {
            switch self {
            case .path: .path
            case .query: .query
            case .header, .basicUser: .header
            }
        }
    }

    static func apply(
        _ head: GatewayRequestHead,
        route: GatewayRoute,
        lookup: (String) -> Live?
    ) -> Result<(head: GatewayRequestHead, used: Live, surfaces: Set<GatewaySurface>, echoes: [Echo]), GatewayRefusal> {
        var used: Live?
        var filled: Set<GatewaySurface> = []
        var echoes: [Echo] = []
        var basicRewritten = false
        func rewrite(_ bytes: [UInt8], at position: Position) -> Result<[UInt8], GatewayRefusal> {
            let found = SecretPlaceholder.occurrences(in: bytes)
            // Fail closed: an encoded placeholder would otherwise go upstream unswapped.
            guard SecretPlaceholder.occurrences(in: percentDecoded(bytes)).count == found.count else {
                return .failure(.encodedPlaceholder)
            }
            guard found.isEmpty == false else { return .success(bytes) }
            var output: [UInt8] = []
            var cursor = 0
            for occurrence in found {
                guard let live = lookup(occurrence.token) else { return .failure(.unknownPlaceholder) }
                guard live.secret == route.secret else { return .failure(.foreignPlaceholder) }
                if let refusal = GatewayAccess.refusal(
                    live.rules, method: head.method, route: route, basePath: live.basePath)
                {
                    return .failure(refusal)
                }
                guard live.surfaces.contains(position.surface) else { return .failure(.surfaceNotAllowed) }
                guard filled.insert(position.surface).inserted else { return .failure(.repeatedPlaceholder) }
                guard let secret = live.value, let value = encode(secret.bytes, at: position) else { return .failure(.unsafeValue) }
                let prefix = Array(live.prefix.utf8)
                var start = occurrence.start
                if prefix.isEmpty == false, start >= prefix.count,
                    Array(bytes[(start - prefix.count)..<start]) == prefix, start - prefix.count >= cursor
                {
                    start -= prefix.count
                }
                output += bytes[cursor..<start]
                output += value
                cursor = occurrence.start + SecretPlaceholder.marker.count + SecretPlaceholder.tokenLength
                used = live
            }
            output += bytes[cursor...]
            return .success(output)
        }
        var rewritten = head
        let target = Array(head.target.utf8)
        let queryStart = target.firstIndex(of: UInt8(ascii: "?")) ?? target.endIndex
        let path = rewrite(Array(target[..<queryStart]), at: .path)
        let query = rewrite(Array(target[queryStart...]), at: .query)
        switch (path, query) {
        case (.failure(let refusal), _), (_, .failure(let refusal)): return .failure(refusal)
        case (.success(let path), .success(let query)):
            rewritten.target = String(decoding: path + query, as: UTF8.self)
        }
        for index in rewritten.headers.indices {
            let value = rewritten.headers[index].value
            if let credentials = basicCredentials(value) {
                // `user:password` behind `Basic`, e.g. git's token-as-password.
                let colon = credentials.firstIndex(of: UInt8(ascii: ":")) ?? credentials.endIndex
                let user = rewrite(Array(credentials[..<colon]), at: .basicUser)
                let password = rewrite(Array(credentials[colon...]), at: .header)
                switch (user, password) {
                case (.failure(let refusal), _), (_, .failure(let refusal)): return .failure(refusal)
                case (.success(let user), .success(let password)):
                    let encoded = Data(user + password).base64EncodedString()
                    rewritten.headers[index].value = "Basic " + encoded
                    // The real value now travels base64-encoded, where a raw scrub cannot see it.
                    echoes.append(Echo(needle: Array(encoded.utf8),
                        replacement: Array(Data(credentials).base64EncodedString().utf8)))
                    basicRewritten = true
                }
                continue
            }
            switch rewrite(Array(value.utf8), at: .header) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let value): rewritten.headers[index].value = String(decoding: value, as: UTF8.self)
            }
        }
        guard let used else { return .failure(.noPlaceholder) }
        if basicRewritten {
            let placeholder = Array(SecretPlaceholder(token: used.token, prefix: used.prefix).text.utf8)
            if let value = used.value {
                echoes += base64Fragments(of: value.bytes).map { Echo(needle: $0, replacement: placeholder) }
            }
        }
        return .success((rewritten, used, filled, echoes))
    }

    /// A response-side rewrite for a form of the secret that leaves the gateway encoded.
    typealias Echo = (needle: [UInt8], replacement: [UInt8])

    /// Base64 text of `value` that holds wherever it sits in a larger base64 string:
    /// one fragment per byte alignment, trimmed to whole three-byte groups, since
    /// the characters touching its edges depend on the neighbouring bytes.
    static func base64Fragments(of value: [UInt8]) -> [[UInt8]] {
        (0..<3).compactMap { skip in
            guard value.count > skip else { return nil }
            let whole = (value.count - skip) / 3 * 3
            let fragment = Array(Data(value[skip..<skip + whole]).base64EncodedString().utf8)
            return fragment.count >= 8 ? fragment : nil
        }
    }

    /// The value as it may appear at `position`, or nil when no encoding keeps
    /// the request's shape. A header value has no escape for a line break, so
    /// CR or LF is refused there; env delivery still carries multi-line values.
    static func encode(_ value: [UInt8], at position: Position) -> [UInt8]? {
        switch position {
        case .header:
            return value.contains { $0 == 13 || $0 == 10 || $0 == 0 } ? nil : value
        case .basicUser:
            return value.contains { $0 == 13 || $0 == 10 || $0 == 0 || $0 == UInt8(ascii: ":") } ? nil : value
        case .path:
            // Refused rather than encoded: an upstream that decodes before
            // routing would still see `/`, `\`, or `..` in the path.
            let reshaping = Array("/\\?#\r\n\0".utf8)
            guard value.contains(where: reshaping.contains) == false,
                zip(value, value.dropFirst()).contains(where: { $0 == 46 && $1 == 46 }) == false
            else { return nil }
            return percentEncode(value) { isUnreserved($0) || Array("!$&'()*+,;=:@".utf8).contains($0) }
        case .query:
            return percentEncode(value, keeping: isUnreserved)
        }
    }

    /// Decoded `Basic` credentials that hold a placeholder, raw or encoded.
    /// Nil leaves the header to the plain rewrite.
    static func basicCredentials(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
            let decoded = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let bytes = Array(decoded)
        guard SecretPlaceholder.occurrences(in: percentDecoded(bytes)).isEmpty == false else { return nil }
        return bytes
    }

    /// One pass of `%XX` decoding; malformed escapes stay as they are.
    static func percentDecoded(_ bytes: [UInt8]) -> [UInt8] {
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
                let high = nibble(bytes[index + 1]), let low = nibble(bytes[index + 2])
            {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    /// RFC 3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~".
    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || byte == 45 || byte == 46 || byte == 95 || byte == 126
    }

    private static func percentEncode(_ bytes: [UInt8], keeping keep: (UInt8) -> Bool) -> [UInt8] {
        let hex = Array("0123456789ABCDEF".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            if keep(byte) {
                output.append(byte)
            } else {
                output += [37, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            }
        }
        return output
    }
}

enum GatewayHeaders {
    static let echoMethods: Set<String> = ["TRACE", "TRACK"]

    /// RFC 9110 hop-by-hop plus framing headers the gateway re-derives.
    /// `host` is dropped so the transport sets it from the bound upstream.
    static let dropOnRequest: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate",
        "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length", "expect",
        "accept-encoding",
    ]
    /// Would let the agent run a different method than the one policy saw.
    static let methodOverrides: Set<String> = ["x-http-method-override", "x-http-method", "x-method-override"]

    /// The agent's headers that may go upstream. Runs before substitution, so
    /// a placeholder in a hop-by-hop header, a `Proxy-*` header, or a header
    /// `Connection` names is never swapped for the real value.
    static func forwardable(_ headers: [(name: String, value: String)]) -> [(name: String, value: String)] {
        let named = Set(headers.filter { $0.name.lowercased() == "connection" }.flatMap {
            $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        })
        return headers.filter { header in
            let name = header.name.lowercased()
            return dropOnRequest.contains(name) == false && name.hasPrefix("proxy-") == false
                && methodOverrides.contains(name) == false && named.contains(name) == false
        }
    }
    /// Sent on every upstream request in place of the agent's own value.
    static let identityEncoding = (name: "Accept-Encoding", value: "identity")

    /// True when no `Content-Encoding` names anything but `identity`.
    static func isIdentityEncoded(_ headers: [(name: String, value: String)]) -> Bool {
        headers.filter { $0.name.lowercased() == "content-encoding" }
            .flatMap { $0.value.split(separator: ",") }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).lowercased() == "identity" }
    }

    static let dropOnResponse: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "te", "trailer",
        "transfer-encoding", "upgrade", "content-length", "content-encoding", "www-authenticate",
    ]
}
