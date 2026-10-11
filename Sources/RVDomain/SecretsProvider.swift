/// Reference to one secret: provider id, item name, optional field selector.
public struct SecretRef: Hashable, Sendable {
    /// Provider id. Always a member of `allowedProviders`.
    public let provider: String
    /// Item name within the provider. Never empty.
    public let item: String
    /// Field selector within the item, if the provider splits items into fields.
    public let field: String?

    /// Offline default provider id. Definitions that name no broker use the
    /// file backend; the agent-definition digest treats this value as the
    /// default and omits it from the canonical projection.
    public static let defaultProvider = "file"

    /// Provider ids the broker accepts. Unknown ids fail closed.
    public static let allowedProviders: Set<String> = [
        defaultProvider, "keychain", "vault-http", "env", "exec",
    ]

    /// Validates provider (non-empty, allowlisted) and item (non-empty). Field passes through.
    public init(provider: String, item: String, field: String? = nil) throws {
        guard Self.allowedProviders.contains(provider) else {
            throw SecretsError.invalidRef(provider)
        }
        guard item.isEmpty == false else {
            throw SecretsError.invalidRef(provider)
        }
        self.provider = provider
        self.item = item
        self.field = field
    }
}

/// Resolved secret material: inline text or a staged file path.
public enum SecretValue: Sendable, Equatable {
    /// Secret bytes held inline.
    case text(String)
    /// Path to a staged file holding the secret.
    case filePath(String)
}

/// Reachability snapshot for one provider.
public struct ProviderHealth: Sendable, Equatable {
    /// Whether the provider is currently usable.
    public let ok: Bool
    /// Authenticated identity the provider sees, if any.
    public let identity: String?

    /// Reports reachability and identity for one provider.
    public init(ok: Bool, identity: String? = nil) {
        self.ok = ok
        self.identity = identity
    }
}

/// Broker failure cause. Carries provider ids or op labels only, never item/field/values.
public enum SecretsError: Error, Sendable, Equatable {
    /// Ref failed validation: unknown or empty provider, or empty item.
    case invalidRef(String)
    /// Provider holds no such item.
    case notFound(String)
    /// Provider refused access.
    case denied(String)
    /// No authenticated principal; no provider was touched.
    case identityRequired
    /// Dynamic lease expired; stale values are never served.
    case leaseExpired(String)
    /// Provider unreachable, sealed, or unregistered.
    case providerDown(String)
    /// Resolved value exceeds the staging cap.
    case oversized(String)
    /// Policy denied the operation.
    case policyDenied
    /// Operation exceeded its budget.
    case timeout(String)
}

/// One secret backend. Trait only; conformances live in RVIsolation and perform IO there.
public protocol SecretsProvider: Sendable {
    /// Provider id. Must be a member of `SecretRef.allowedProviders`.
    var id: String { get }
    /// Resolves one ref to its value.
    func resolve(_ ref: SecretRef) async throws -> SecretValue
    /// Reports reachability and the authenticated identity, if any.
    func health() async -> ProviderHealth
}
