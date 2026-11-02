import Foundation

extension AWSSigningBinding {
    public static let unusableCredentials = "the AWS profile did not return usable credentials"
}

extension SecretDefinition {
    /// The values a leak scan looks for: the value itself, or for an AWS
    /// profile each credential in it. Nil when an AWS profile's output is
    /// not a usable credential set.
    /// A value that is not a lasting token (an AWS credential set, or an
    /// OAuth token only the gateway keeps fresh) is spent only by the
    /// gateway: MCP servers and `audit forward` headers refuse it.
    public var gatewayOnly: Bool {
        switch source {
        case .awsProfile, .oauth: true
        default: false
        }
    }

    public func credentialParts(_ value: SecretValue) -> [SecretValue]? {
        if case .oauth = source { return OAuthAccessToken(value).map { [$0.token] } }
        guard case .awsSigV4 = delivery else { return [value] }
        return AWSCredentialSet(value)?.values
    }

    /// Why `credentialParts` returned nil.
    public var unusableCredentials: String {
        if case .oauth = source { return OAuthAccessToken.unusable }
        return AWSSigningBinding.unusableCredentials
    }
}

/// The credential set an `awsProfile` source resolves to: the
/// `credential_process` JSON that `aws configure export-credentials` prints.
struct AWSCredentialSet: Sendable {
    var accessKeyID: SecretValue
    var secretAccessKey: SecretValue
    var sessionToken: SecretValue?
    /// From `Expiration`; nil for long-term keys.
    var expires: Date?

    /// Nil unless it is version 1 JSON whose keys are header-safe text, and
    /// whose `Expiration`, when present, is an instant.
    init?(_ value: SecretValue) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(value.revealed())) as? [String: Any],
            object["Version"] as? Int == 1,
            let key = object["AccessKeyId"] as? String, Self.keyID(key), let keyValue = SecretValue(key),
            let secret = object["SecretAccessKey"] as? String, Self.printable(secret), let secretValue = SecretValue(secret)
        else { return nil }
        accessKeyID = keyValue
        secretAccessKey = secretValue
        if let raw = object["SessionToken"] {
            guard let token = raw as? String, Self.printable(token), let tokenValue = SecretValue(token) else { return nil }
            sessionToken = tokenValue
        }
        if let raw = object["Expiration"] {
            guard let text = raw as? String, let instant = Self.instant(text) else { return nil }
            expires = instant
        }
    }

    var signing: AWSSigV4.Credentials {
        AWSSigV4.Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken)
    }

    /// Every part a response might echo; S3 error bodies carry the key id.
    var values: [SecretValue] { [accessKeyID, secretAccessKey] + (sessionToken.map { [$0] } ?? []) }

    /// Access key ids are upper-case letters and digits; nothing that could
    /// move the credential scope's `/` or the header's `,`.
    static func keyID(_ text: String) -> Bool {
        (1...128).contains(text.utf8.count)
            && text.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
    }

    /// Visible ASCII only, so the value is safe in a header.
    static func printable(_ text: String) -> Bool {
        text.isEmpty == false && text.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }

    /// The CLI writes `2027-01-15T09:00:00+00:00`, sometimes with fractional seconds.
    static func instant(_ text: String) -> Date? {
        if let date = SecretExpiry.parse(text) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

extension AWSSigV4 {
    /// True for any SigV4-family `Authorization` (`AWS4-HMAC-SHA256`, SigV4a).
    static func isSigV4(_ authorization: String) -> Bool {
        authorization.hasPrefix("AWS4-")
    }

    /// The access key id in `Credential=<key>/<scope>`, or nil.
    static func keyID(inAuthorization authorization: String) -> String? {
        guard let range = authorization.range(of: "Credential=") else { return nil }
        let rest = authorization[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let key = rest[..<slash]
        return key.isEmpty ? nil : String(key)
    }
}

extension SecretGateway.Entry {
    /// What a response must not carry: every generation's value, or for an
    /// AWS entry each generation's key id, secret, and session token.
    var scrubbed: [SecretValue] {
        let generations = [value] + previous
        guard signing != nil else { return generations }
        return generations.flatMap { AWSCredentialSet($0)?.values ?? [$0] }
    }
}

extension SecretGateway {
    /// `x-amz-content-sha256` modes the gateway can sign as sent: no chunk
    /// signature chains to the agent's discarded seed signature.
    static let unsignedPayloadModes: Set<String> = ["UNSIGNED-PAYLOAD", "STREAMING-UNSIGNED-PAYLOAD-TRAILER"]

    typealias Admitted = (head: GatewayRequestHead, used: GatewaySubstitution.Live, surfaces: Set<GatewaySurface>)

    /// Admits a SigV4 request: the key id must be this route's live AWS
    /// placeholder, the request must sit inside the secret's allow rules,
    /// and no copy of any placeholder may appear anywhere else. Returns the
    /// head without the headers the signer owns.
    func admitAWS(
        _ head: GatewayRequestHead, route: GatewayRoute, authorization: String, presented: inout [Entry]
    ) -> Result<Admitted, GatewayRefusal> {
        guard let key = AWSSigV4.keyID(inAuthorization: authorization) else { return .failure(.malformed) }
        let found = SecretPlaceholder.occurrences(in: Array(key.utf8))
        guard found.count == 1, let token = found.first?.token, SecretPlaceholder(token: token, prefix: "").text == key
        else { return .failure(.awsKeyMismatch) }
        guard let live = entry(token) else { return .failure(.unknownPlaceholder) }
        presented.append(live)
        guard live.secret == route.secret else { return .failure(.foreignPlaceholder) }
        guard live.signing != nil else { return .failure(.awsKeyMismatch) }
        let used = Self.live(live, token: token)
        if let refusal = GatewayAccess.refusal(live.rules, method: head.method, route: route, basePath: used.basePath) {
            return .failure(refusal)
        }
        if let mode = head.header("X-Amz-Content-Sha256"), mode.hasPrefix("STREAMING-"),
            Self.unsignedPayloadModes.contains(mode) == false
        {
            return .failure(.awsSignedStreaming)
        }
        var stripped = head
        stripped.headers = head.headers.filter { AWSSigV4.ownedHeaders.contains($0.name.lowercased()) == false }
        // The key id is the one place an AWS placeholder belongs. Elsewhere
        // it, or any other placeholder, is refused as it would be anywhere.
        switch GatewaySubstitution.apply(stripped, route: route, lookup: { token in self.entry(token).map { Self.live($0, token: token) } }) {
        case .failure(.noPlaceholder): return .success((stripped, used, [.header]))
        case .failure(let refusal): return .failure(refusal)
        case .success: return .failure(.surfaceNotAllowed)
        }
    }

    /// The substitution view of an entry. An AWS entry allows no surface, so
    /// its credential set is never written into a request.
    static func live(_ entry: Entry, token: String) -> GatewaySubstitution.Live {
        GatewaySubstitution.Live(
            token: token, secret: entry.secret, prefix: entry.prefix, value: entry.value,
            surfaces: entry.signing == nil ? entry.surfaces : [], rules: entry.rules,
            basePath: URLComponents(url: entry.upstream, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
    }

    /// The forwarded headers plus a signature by the real credentials for
    /// `url`. The body is hashed here unless the agent chose an unsigned mode.
    func awsSigned(
        _ entry: Entry, binding: AWSSigningBinding, method: String, url: URL,
        headers: [(name: String, value: String)], body: Data, payloadMode: String?
    ) -> Result<[(name: String, value: String)], GatewayRefusal> {
        guard let credentials = AWSCredentialSet(entry.value) else { return .failure(.unsafeValue) }
        let payloadHash = payloadMode.flatMap { Self.unsignedPayloadModes.contains($0) ? $0 : nil }
            ?? AWSSigV4.payloadHash(Array(body))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let signedInput = [(name: "host", value: Self.hostHeader(url))] + headers.filter { Self.signsHeader($0.name) }
        guard let signed = AWSSigV4.sign(
            AWSSigV4.Request(
                method: method, path: components?.percentEncodedPath ?? "/", query: components?.percentEncodedQuery,
                headers: signedInput, payloadHash: payloadHash),
            credentials: credentials.signing, scope: AWSSigV4.Scope(region: binding.region, service: binding.service),
            at: now(), options: binding.service == "s3" ? .s3 : AWSSigV4.Options())
        else { return .failure(.malformed) }
        return .success(headers + signed.headers)
    }

    /// Headers whose values the transport sends exactly as given.
    static func signsHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "content-type" || lower == "content-md5" || lower.hasPrefix("x-amz-")
    }

    /// `Host` as the transport writes it for `url`.
    static func hostHeader(_ url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port, port != 443 else { return host }
        return "\(host):\(port)"
    }
}
