/// One request through the secret gateway that a binding's `approve` rule
/// holds for a human. Carries no secret: placeholders are redacted from
/// `path`, and the full target and body are bound only by their hashes, so
/// a retried request with any other query or body is a different action.
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
    public var scope: ActionScope

    /// Policy judges the binding's rule, not typed effects.
    public var effects: ActionEffects { ActionEffects() }
    public var resources: ResourceScope { .none }

    public init(
        secret: String, method: String, host: String, path: String, targetSHA256: String, bodySHA256: String,
        bodyBytes: Int, scope: ActionScope = ActionScope()
    ) {
        self.fingerprint = ActionFingerprint(
            rawValue: "secret-request:\(secret):\(method):\(host):\(targetSHA256):\(bodySHA256)")
        self.secret = secret
        self.method = method
        self.host = host
        self.path = path
        self.targetSHA256 = targetSHA256
        self.bodySHA256 = bodySHA256
        self.bodyBytes = bodyBytes
        self.scope = scope
    }

    /// What a reviewer reads: `POST api.github.com/repos/o/r/merges (GITHUB_TOKEN, 120 bytes)`.
    public var summary: String {
        "\(method) \(host)\(path) (\(secret), \(bodyBytes) bytes)"
    }
}
