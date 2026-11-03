import Foundation

/// A resolved secret, parsed once from the provider's bytes. This file is the
/// resolver adapter: `AWSCredentialSet` and `OAuthAccessToken` can only be
/// built here (their initializers are `fileprivate`), so no other code can
/// reinterpret a plain `SecretValue` as a credential set or an access token.
enum ResolvedSecret: Sendable, Equatable {
    /// A lasting value the gateway substitutes or a process may hold.
    case token(SecretValue)
    /// An `awsProfile` source's credential set; only the gateway signs with it.
    case awsCredentials(AWSCredentialSet)
    /// An `oauth` source's minted access token; only the gateway spends it.
    case oauth(OAuthAccessToken)

    /// The value as plain text for a consumer that is not the gateway; nil for
    /// the gateway-only kinds.
    var lastingToken: SecretValue? {
        switch self {
        case .token(let value): value
        case .awsCredentials, .oauth: nil
        }
    }

    /// Every secret part a response might echo or a leak scan looks for.
    var parts: [SecretValue] {
        switch self {
        case .token(let value): [value]
        case .awsCredentials(let credentials): credentials.values
        case .oauth(let minted): [minted.token]
        }
    }

    /// What the audit fingerprint is taken over. An AWS credential set keeps
    /// the exact bytes the provider returned, so fingerprints do not change.
    var fingerprintInput: SecretValue {
        switch self {
        case .token(let value): value
        case .awsCredentials(let credentials): credentials.raw
        case .oauth(let minted): minted.token
        }
    }

    /// The instant the provider says the value stops working, if it says.
    var expires: Date? {
        switch self {
        case .token: nil
        case .awsCredentials(let credentials): credentials.expires
        case .oauth(let minted): minted.expires
        }
    }

    /// Reads `value` as the kind `source` and `delivery` call for. Nil when
    /// an `oauth` or `awsSigV4` value is not usable; a plain token never fails.
    static func parse(_ value: SecretValue, source: SecretSource, delivery: SecretDelivery) -> ResolvedSecret? {
        switch (source, delivery) {
        case (.oauth, _): OAuthAccessToken(value).map { .oauth($0) }
        case (_, .awsSigV4): AWSCredentialSet(value).map { .awsCredentials($0) }
        case (_, .gateway), (_, .environment): .token(value)
        }
    }

    static func parse(_ value: SecretValue, for definition: SecretDefinition) -> ResolvedSecret? {
        parse(value, source: definition.source, delivery: definition.delivery)
    }
}

extension SecretResolver {
    /// Reads `definition`'s source and parses the result.
    func resolveCredential(_ definition: SecretDefinition) -> Result<ResolvedSecret, SecretResolutionError> {
        resolve(definition.source).flatMap { value in
            guard let parsed = ResolvedSecret.parse(value, for: definition) else {
                return .failure(.invalidValue(definition.unusableCredentials))
            }
            return .success(parsed)
        }
    }

    /// Plain text for a consumer that is not the gateway. `.success(nil)` for
    /// a gateway-only secret, whose source is then not read at all.
    public func resolveText(_ definition: SecretDefinition) -> Result<SecretValue?, SecretResolutionError> {
        guard definition.spendsAsText else { return .success(nil) }
        return resolveCredential(definition).map(\.lastingToken)
    }
}

extension SecretDefinition {
    /// False for a value only the gateway may spend (an AWS credential set, or
    /// an OAuth token the gateway keeps fresh): MCP servers and `audit forward`
    /// headers get nothing for it.
    var spendsAsText: Bool {
        switch source {
        case .awsProfile, .oauth: false
        case .keychain, .hostEnvironment, .onePassword, .vault, .awsSecretsManager, .infisical, .bitwarden,
            .gcp, .azure:
            true
        }
    }

    /// The values a leak scan looks for: the value itself, or for an AWS
    /// profile each credential in it. Nil when the output is not usable.
    public func credentialParts(_ value: SecretValue) -> [SecretValue]? {
        ResolvedSecret.parse(value, for: self)?.parts
    }

    /// Why `credentialParts` returned nil.
    public var unusableCredentials: String {
        if case .oauth = source { return OAuthAccessToken.unusable }
        return AWSSigningBinding.unusableCredentials
    }
}

/// The credential set an `awsProfile` source resolves to: the
/// `credential_process` JSON that `aws configure export-credentials` prints.
struct AWSCredentialSet: Sendable, Equatable {
    // Immutable, so the parts the gateway signs with always come from `raw`.
    let accessKeyID: SecretValue
    let secretAccessKey: SecretValue
    let sessionToken: SecretValue?
    /// From `Expiration`; nil for long-term keys.
    let expires: Date?
    /// The provider's exact bytes, which the audit fingerprint is taken over.
    let raw: SecretValue

    /// Nil unless it is version 1 JSON whose keys are header-safe text, and
    /// whose `Expiration`, when present, is an instant.
    fileprivate init?(_ value: SecretValue) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(value.revealed())) as? [String: Any],
            object["Version"] as? Int == 1,
            let key = object["AccessKeyId"] as? String, Self.keyID(key), let keyValue = SecretValue(key),
            let secret = object["SecretAccessKey"] as? String, Self.printable(secret), let secretValue = SecretValue(secret)
        else { return nil }
        raw = value
        accessKeyID = keyValue
        secretAccessKey = secretValue
        if let rawToken = object["SessionToken"] {
            guard let token = rawToken as? String, Self.printable(token), let tokenValue = SecretValue(token) else { return nil }
            sessionToken = tokenValue
        } else {
            sessionToken = nil
        }
        if let rawExpiration = object["Expiration"] {
            guard let text = rawExpiration as? String, let instant = Self.instant(text) else { return nil }
            expires = instant
        } else {
            expires = nil
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

/// The access token an `oauth` source resolves to and when it expires.
/// It crosses the resolver as `{"access_token": …, "expires_at": epoch}` so
/// the broker can bound the gateway entry by it, as with an AWS credential set.
struct OAuthAccessToken: Sendable, Equatable {
    static let unusable = "the token endpoint's answer could not be used"

    let token: SecretValue
    let expires: Date?

    fileprivate init?(_ value: SecretValue) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(value.bytes))) as? [String: Any],
            let text = object["access_token"] as? String, OAuthTokenMinter.usableToken(text),
            let token = SecretValue(text)
        else { return nil }
        self.token = token
        expires = (object["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    static func encode(token: String, expires: Date?) -> SecretValue? {
        var object: [String: Any] = ["access_token": token]
        if let expires {
            // A date this far out has no epoch second to write; leave it off rather than trap.
            guard let epoch = Int(exactly: expires.timeIntervalSince1970.rounded(.down)) else { return nil }
            object["expires_at"] = epoch
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return SecretValue(String(decoding: data, as: UTF8.self))
    }
}
