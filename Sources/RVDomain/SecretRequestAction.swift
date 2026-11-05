/// One request through the secret gateway that a binding's `approve` rule
/// holds for a human. Carries no secret: placeholders are redacted from
/// `path`, and the full target, headers and body are bound only by their
/// hashes, so a retried request with any other query, body or (non-volatile)
/// header is a different action.
public struct SecretRequestAction: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    /// The secret's name, e.g. `GITHUB_TOKEN`.
    public var secret: String
    public var method: String
    /// The upstream host the gateway would send to.
    public var host: String
    /// Request path with placeholders redacted and no query.
    public var path: String
    /// SHA-256 of the request target as the agent sent it, query included.
    public var targetSHA256: String
    /// SHA-256 of the body as the agent sent it. The body is never substituted.
    public var bodySHA256: String
    public var bodyBytes: Int
    /// SHA-256 over the forwarded request headers (names lowercased and
    /// sorted, placeholders redacted), less the volatile ones an SDK changes
    /// between retries. Headers can select the operation (`X-Amz-Target`).
    public var headersSHA256: String
    /// The operation-selecting headers among them, for the approver to read.
    /// Names are lowercase and values carry no placeholder.
    public var operationHeaders: [Header]
    public var scope: ActionScope

    public struct Header: Sendable, Equatable, Codable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Policy judges the binding's rule, not typed effects.
    public var effects: ActionEffects { ActionEffects() }
    public var resources: ResourceScope { .none }

    public init(
        secret: String, method: String, host: String, path: String, targetSHA256: String, bodySHA256: String,
        bodyBytes: Int, headersSHA256: String, operationHeaders: [Header], scope: ActionScope = ActionScope()
    ) {
        self.fingerprint = ActionFingerprint.make(
            "secret-request",
            [
                .field(secret), .field(method), .field(host), .field(targetSHA256),
                .field(bodySHA256), .field(headersSHA256),
            ])
        self.secret = secret
        self.method = method
        self.host = host
        self.path = path
        self.targetSHA256 = targetSHA256
        self.bodySHA256 = bodySHA256
        self.bodyBytes = bodyBytes
        self.headersSHA256 = headersSHA256
        self.operationHeaders = operationHeaders
        self.scope = scope
    }

    /// What a reviewer reads: `POST api.github.com/repos/o/r/merges (GITHUB_TOKEN, 120 bytes)`,
    /// then the operation-selecting headers when the request has any.
    public var summary: String {
        "\(method) \(host)\(path) (\(secret), \(bodyBytes) bytes)" + (headerSummary.map { " [\($0)]" } ?? "")
    }

    /// `x-amz-target: SecretsManager.GetSecretValue, content-type: application/json`, or nil.
    public var headerSummary: String? {
        operationHeaders.isEmpty ? nil : operationHeaders.map { "\($0.name): \($0.value)" }.joined(separator: ", ")
    }
}
