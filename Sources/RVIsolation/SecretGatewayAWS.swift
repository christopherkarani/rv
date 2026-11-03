import Foundation

extension AWSSigningBinding {
    public static let unusableCredentials = "the AWS profile did not return usable credentials"
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
        if let mode = head.header("X-Amz-Content-Sha256"), Self.unsignedPayloadModes.contains(mode),
            live.signing?.isS3 != true
        {
            return .failure(.awsUnsignedPayload)
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
            token: token, secret: entry.secret, prefix: entry.prefix, value: entry.credential.substitutable,
            surfaces: entry.signing == nil ? entry.surfaces : [], rules: entry.rules,
            basePath: URLComponents(url: entry.upstream, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
    }

    /// The forwarded headers plus a signature by the real credentials for
    /// `url`. The body is hashed here unless the agent chose an unsigned mode.
    func awsSigned(
        _ entry: Entry, binding: AWSSigningBinding, method: String, url: URL,
        headers: [(name: String, value: String)], body: Data, payloadMode: String?
    ) -> Result<[(name: String, value: String)], GatewayRefusal> {
        guard case .signed(let credentials, _) = entry.credential else { return .failure(.unsafeValue) }
        let payloadHash = payloadMode.flatMap { Self.unsignedPayloadModes.contains($0) ? $0 : nil }
            ?? AWSSigV4.payloadHash(Array(body))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let signedInput = [(name: "host", value: Self.hostHeader(url))] + headers.filter { Self.signsHeader($0.name) }
        guard let signed = AWSSigV4.sign(
            AWSSigV4.Request(
                method: method, path: components?.percentEncodedPath ?? "/", query: components?.percentEncodedQuery,
                headers: signedInput, payloadHash: payloadHash),
            credentials: credentials.signing, scope: AWSSigV4.Scope(region: binding.region, service: binding.service),
            at: now(), options: binding.isS3 ? .s3 : AWSSigV4.Options())
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

extension SecretGateway.Entry {
    /// What an entry spends. A signed entry holds a parsed AWS credential set,
    /// so an entry that signs with something other than one cannot be built.
    enum Credential: Sendable, Equatable {
        /// Written into requests where the placeholder sits.
        case substituted(SecretValue)
        /// Never written into a request; the gateway re-signs with it.
        case signed(AWSCredentialSet, AWSSigningBinding)

        var signing: AWSSigningBinding? {
            switch self {
            case .substituted: nil
            case .signed(_, let binding): binding
            }
        }

        /// The value a placeholder is swapped for; nil for a signed entry.
        var substitutable: SecretValue? {
            switch self {
            case .substituted(let value): value
            case .signed: nil
            }
        }

        /// What a response must not carry: the value, or each AWS credential part.
        var scrubbed: [SecretValue] {
            switch self {
            case .substituted(let value): [value]
            case .signed(let credentials, _): credentials.values
            }
        }

        /// This entry's credential with a refresh's result, or nil when the
        /// result is not the kind this entry spends.
        func replacing(with resolved: ResolvedSecret) -> Credential? {
            switch (self, resolved) {
            case (.substituted, .token(let value)): .substituted(value)
            case (.substituted, .oauth(let minted)): .substituted(minted.token)
            case (.signed(_, let binding), .awsCredentials(let credentials)): .signed(credentials, binding)
            case (.substituted, .awsCredentials), (.signed, .token), (.signed, .oauth): nil
            }
        }
    }

    /// What a response must not carry: every generation's value, or for an
    /// AWS entry each generation's key id, secret, and session token.
    var scrubbed: [SecretValue] {
        ([credential] + previous).flatMap(\.scrubbed)
    }
}

extension SecretGateway.Entry.Credential {
    /// The credential a gateway entry spends for `resolved` under `delivery`.
    /// Nil for environment delivery, which holds no gateway entry, and for a
    /// pairing `ResolvedSecret.parse` never produces.
    init?(_ resolved: ResolvedSecret, delivery: SecretDelivery) {
        switch (delivery, resolved) {
        case (.gateway, .token(let value)): self = .substituted(value)
        case (.gateway, .oauth(let minted)): self = .substituted(minted.token)
        case (.awsSigV4(let binding), .awsCredentials(let credentials)): self = .signed(credentials, binding)
        case (.gateway, .awsCredentials), (.awsSigV4, .token), (.awsSigV4, .oauth), (.environment, _): return nil
        }
    }
}
