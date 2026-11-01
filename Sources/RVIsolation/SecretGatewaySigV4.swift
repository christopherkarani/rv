import Foundation
import RVDomain

/// AWS Signature Version 4, header form. Pure: the clock and the
/// credentials come in as arguments, and nothing is read or written.
///
/// The gateway discards the agent's signature and signs the request it
/// forwards with real credentials. The signer owns `Authorization`,
/// `X-Amz-Date`, `X-Amz-Security-Token`, and `X-Amz-Content-Sha256`: copies
/// in the input are dropped, never signed.
enum AWSSigV4 {
    static let algorithm = "AWS4-HMAC-SHA256"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let ownedHeaders: Set<String> = [
        "authorization", "x-amz-date", "x-amz-security-token", "x-amz-content-sha256",
    ]

    struct Credentials: Sendable {
        var accessKeyID: SecretValue
        var secretAccessKey: SecretValue
        var sessionToken: SecretValue?
    }

    struct Scope: Sendable, Equatable {
        var region: String
        var service: String
    }

    struct Options: Sendable, Equatable {
        /// Resolve `.`/`..` and collapse repeated slashes before encoding.
        var normalizePath = true
        /// Encode the wire path again, so `%` becomes `%25`. Every service but S3.
        var doubleEncodePath = true
        /// Sign `X-Amz-Security-Token`; when false it is sent unsigned.
        var signSessionToken = true
        /// Send and sign `X-Amz-Content-Sha256`. S3 requires it.
        var sendPayloadHash = true

        /// S3 signs the single-encoded path exactly as sent.
        static let s3 = Options(normalizePath: false, doubleEncodePath: false)
    }

    /// The request as it goes on the wire.
    struct Request: Sendable {
        var method: String
        /// Percent-encoded path, without the query.
        var path: String
        /// Raw query, without `?`.
        var query: String?
        var headers: [(name: String, value: String)]
        /// Hex SHA-256 of the body, or `UNSIGNED-PAYLOAD`.
        var payloadHash: String
    }

    /// Carries the session token and the real access-key id, so it never prints.
    struct Signed: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        var canonicalRequest: String
        var stringToSign: String
        var signature: String
        /// Headers to add to the forwarded request.
        var headers: [(name: String, value: String)]

        var description: String { "<signed request redacted>" }
        var debugDescription: String { description }
    }

    static func payloadHash(_ body: [UInt8]) -> String { RVDigest.sha256Hex(body) }

    /// Nil when the path or query cannot be decoded, or a credential is not text.
    static func sign(
        _ request: Request, credentials: Credentials, scope: Scope, at date: Date, options: Options
    ) -> Signed? {
        guard let accessKeyID = credentials.accessKeyID.text,
            let uri = canonicalURI(request.path, options: options),
            let query = canonicalQuery(request.query)
        else { return nil }
        var tokenHeader: (name: String, value: String)?
        if let sessionToken = credentials.sessionToken {
            guard let text = sessionToken.text else { return nil }
            tokenHeader = ("X-Amz-Security-Token", text)
        }
        let stamp = timestamp(date)
        var owned = [(name: "X-Amz-Date", value: stamp.dateTime)]
        if options.sendPayloadHash { owned.append(("X-Amz-Content-Sha256", request.payloadHash)) }
        let signedInput = request.headers.filter { ownedHeaders.contains($0.name.lowercased()) == false }
            + owned + (options.signSessionToken ? tokenHeader.map { [$0] } ?? [] : [])
        let (canonicalHeaders, signedHeaders) = canonicalHeaders(signedInput)
        let canonicalRequest = [request.method, uri, query, canonicalHeaders, signedHeaders, request.payloadHash]
            .joined(separator: "\n")
        let credentialScope = "\(stamp.date)/\(scope.region)/\(scope.service)/aws4_request"
        let stringToSign = [
            algorithm, stamp.dateTime, credentialScope, RVDigest.sha256Hex(Array(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let signature = hex(RVDigest.hmacSHA256(
            key: signingKey(credentials.secretAccessKey, date: stamp.date, scope: scope),
            message: Array(stringToSign.utf8)))
        let authorization = "\(algorithm) Credential=\(accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return Signed(
            canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature,
            headers: [("Authorization", authorization)] + owned + (tokenHeader.map { [$0] } ?? []))
    }

    static func signingKey(_ secret: SecretValue, date: String, scope: Scope) -> [UInt8] {
        var key = Array("AWS4".utf8) + secret.revealed()
        for part in [date, scope.region, scope.service, "aws4_request"] {
            key = RVDigest.hmacSHA256(key: key, message: Array(part.utf8))
        }
        return key
    }

    // MARK: Canonical form

    static func canonicalURI(_ path: String, options: Options) -> String? {
        let source = path.isEmpty ? "/" : path
        let normalized = options.normalizePath ? normalize(source) : source
        if options.doubleEncodePath {
            return encode(Array(normalized.utf8), keepSlash: true)
        }
        var segments: [String] = []
        for segment in normalized.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = percentDecode(segment) else { return nil }
            segments.append(encode(decoded, keepSlash: false))
        }
        return segments.joined(separator: "/")
    }

    /// RFC 3986 dot-segment removal, plus collapsing repeated slashes.
    static func normalize(_ path: String) -> String {
        var stack: [Substring] = []
        for segment in path.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = stack.popLast()
            default: stack.append(segment)
            }
        }
        let joined = "/" + stack.joined(separator: "/")
        return stack.isEmpty || path.hasSuffix("/") == false ? joined : joined + "/"
    }

    static func canonicalQuery(_ query: String?) -> String? {
        guard let query, query.isEmpty == false else { return "" }
        var pairs: [(key: String, value: String)] = []
        for parameter in query.split(separator: "&") {
            let parts = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = percentDecode(parts[0]),
                let value = parts.count > 1 ? percentDecode(parts[1]) : []
            else { return nil }
            pairs.append((encode(key, keepSlash: false), encode(value, keepSlash: false)))
        }
        return pairs.sorted { $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    /// Lowercased names, sorted; repeated names joined with commas in order;
    /// values trimmed with inner runs of spaces collapsed.
    static func canonicalHeaders(_ headers: [(name: String, value: String)]) -> (canonical: String, signed: String) {
        var values: [String: [String]] = [:]
        for header in headers {
            values[header.name.lowercased(), default: []].append(trimAll(header.value))
        }
        let names = values.keys.sorted()
        let canonical = names.map { "\($0):\(values[$0, default: []].joined(separator: ","))\n" }.joined()
        return (canonical, names.joined(separator: ";"))
    }

    static func trimAll(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    static func encode(_ bytes: [UInt8], keepSlash: Bool) -> String {
        var out = ""
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
                UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: "/") where keepSlash:
                out.append("/")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Nil on a `%` not followed by two hex digits.
    static func percentDecode(_ text: Substring) -> [UInt8]? {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count,
                    let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
                else { return nil }
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `yyyyMMdd'T'HHmmss'Z'` and `yyyyMMdd`, in UTC.
    static func timestamp(_ date: Date) -> (dateTime: String, date: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return (day + String(format: "T%02d%02d%02dZ", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0), day)
    }
}
