import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVDomain
import RVFileStore
import RVPolicy

// MARK: - Environment provider

/// Process-environment secrets provider (E1-A).
///
/// Ref mapping: `ref.item` names the environment variable. Environment
/// variables have no sub-values, so a ref carrying a field can never
/// resolve and fails closed as `.notFound("env")`, mirroring the file
/// provider's unknown-field mapping. A missing variable is `.notFound`;
/// a present-but-empty variable resolves as an explicit empty secret,
/// mirroring the file provider's explicit-empty rule.
///
/// The environment is an injected closure so production reads the live
/// process environment while tests pass fixed maps. Reads cannot fail,
/// so `health` is always reachable with a nil identity (no auth).
///
/// Lives in the factory file because E1-A owns this file only: the
/// provider exists solely as factory output, and a sibling ticket owns
/// every other source file.
public struct EnvSecretsProvider: SecretsProvider, Sendable {
    /// Provider id. Always a member of `SecretRef.allowedProviders`.
    public var id: String { "env" }

    /// Environment snapshot source: variable names to values.
    public var environment: @Sendable () -> [String: String]

    /// Reads through `environment`. Production passes the default live
    /// process environment; tests pass fixed maps.
    public init(
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.environment = environment
    }

    /// Resolves one env-backed ref. Missing variables and field-carrying
    /// refs fail closed as `.notFound`; the variable name never echoes.
    public func resolve(_ ref: SecretRef) async throws -> SecretValue {
        guard ref.field == nil, let value = environment()[ref.item] else {
            throw SecretsError.notFound(id)
        }
        return .text(value)
    }

    /// The environment is always readable, so always reachable. No auth,
    /// so `identity` is always nil.
    public func health() async -> ProviderHealth {
        ProviderHealth(ok: true)
    }
}

// MARK: - Factory errors

/// Provider-factory failure. Flat fixed labels only: the factory
/// surfaces WHICH config broke, never endpoints, mounts, credentials,
/// items, fields, or values. Every case fails closed with zero
/// providers; the caller (E1-C) fails the launch on any of them.
public enum SecretsProviderFactoryError: Error, Sendable, Equatable {
    /// `secrets-providers.json` is present but unusable (unsafe, corrupt,
    /// oversized). The operator config is untrustworthy, so no provider
    /// is constructed even though bindings do not gate construction.
    case providersInvalid
    /// `vault.json` is present but unusable (unsafe, corrupt, oversized,
    /// or failing Vault client validation). A half-understood Vault
    /// config must not silently degrade to local-only providers.
    case vaultConfigInvalid
    /// `vault.json` is valid but `vault-approle.json` is missing or
    /// unusable. AppRole has no empty default: Vault without usable
    /// credentials fails the factory, never drops Vault silently.
    case vaultCredentialsInvalid
    /// Vault config plus credentials passed factory validation but the
    /// client init still rejected them (live pinned TLS on a platform
    /// without an enforcement hook). Defense in depth; unreachable on
    /// macOS, reachable on Linux with a pinned live client.
    case vaultMisconfigured
}

// MARK: - Vault endpoint config

/// Validated Vault endpoint config loaded from `vault.json` (E1-A).
///
/// The operator config directory holds endpoint config (`vault.json`)
/// apart from AppRole credentials (`vault-approle.json`, loaded by
/// `VaultAppRoleStore`): endpoints are reviewable, non-secret operator
/// intent, while ids stay in their own capped owner-only document.
/// Shape: `{"version":1,"endpoint":"https://…","mount":"secret",
/// "tls":"system","timeoutSeconds":10,"wrapTTL":"30s"}`. Only `endpoint`
/// is required; every other member defaults to the matching
/// `VaultHTTPClient` default. Key sets are closed and every member is
/// validated through the client's own `validate` functions, so the
/// factory adds no validation logic of its own and client init after a
/// successful load can only fail on platform pinning.
struct VaultEndpointConfig: Sendable, Equatable {
    /// Vault base URL (scheme, host, port only).
    let endpoint: URL
    /// KV-v2 mount.
    let mount: String
    /// System CA or pinned leaf.
    let tls: VaultTLSConfig
    /// Per-request timeout in seconds.
    let timeoutSeconds: Double
    /// Response-wrapping TTL, or nil for direct reads.
    let wrapTTL: String?
}

/// Loads validated Vault endpoint config from `vault.json`.
///
/// Missing files (or a missing directory) load as nil: Vault is
/// opt-in, and absence simply omits the provider. Every other failure
/// — unsafe location, unreadable, oversized, corrupt — fails closed as
/// `.vaultConfigInvalid`, never as absent.
enum VaultEndpointStore {
    /// Endpoint config file name beside the sibling operator stores.
    static let fileName = "vault.json"
    /// Largest config document accepted. A pinned DER leaf caps at
    /// 16 KiB (~22 KiB base64), so 32 KiB covers the largest honest
    /// document with headroom and nothing more.
    static let maximumBytes = 32_768

    /// Loads config from `fileName` under `configDirectory`, or nil
    /// when no Vault config is present.
    static func load(
        from configDirectory: URL
    ) -> Result<VaultEndpointConfig?, SecretsProviderFactoryError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data).map { .some($0) }
        case .failure(.missing):
            return .success(nil)
        case .failure(.inaccessible), .failure(.unsafeLocation),
            .failure(.unreadable), .failure(.oversized):
            return .failure(.vaultConfigInvalid)
        }
    }

    /// Decodes plus validates one config document.
    static func decode(
        _ data: Data
    ) -> Result<VaultEndpointConfig, SecretsProviderFactoryError> {
        guard data.count <= maximumBytes else {
            return .failure(.vaultConfigInvalid)
        }
        guard let document = try? JSONDecoder().decode(
            VaultEndpointDocument.self, from: data
        ),
            let config = try? validated(document)
        else {
            return .failure(.vaultConfigInvalid)
        }
        return .success(config)
    }

    /// Defaults plus client validation. Throws on any structural or
    /// validation failure; the caller collapses every throw to
    /// `.vaultConfigInvalid` with no payload.
    private static func validated(
        _ document: VaultEndpointDocument
    ) throws -> VaultEndpointConfig {
        guard document.version == 1 else {
            throw VaultConfigurationError.invalidEndpoint
        }
        guard let endpoint = URL(string: document.endpoint) else {
            throw VaultConfigurationError.invalidEndpoint
        }
        try VaultHTTPClient.validate(endpoint: endpoint)
        let mount = document.mount ?? VaultHTTPClient.defaultMount
        try VaultHTTPClient.validate(mount: mount)
        let tls = try tlsConfig(document.tls)
        try VaultHTTPClient.validate(tls: tls)
        let timeout = document.timeoutSeconds ?? VaultHTTPClient.defaultTimeoutSeconds
        try VaultHTTPClient.validate(timeoutSeconds: timeout)
        try VaultHTTPClient.validate(wrapTTL: document.wrapTTL)
        return VaultEndpointConfig(
            endpoint: endpoint, mount: mount, tls: tls,
            timeoutSeconds: timeout, wrapTTL: document.wrapTTL
        )
    }

    /// TLS member: `"system"`, or `{"pinnedLeafDER":"<base64>"}`.
    private static func tlsConfig(
        _ member: VaultTLSMember?
    ) throws -> VaultTLSConfig {
        guard let member else { return .system }
        switch member {
        case .system:
            return .system
        case .pinned(let base64):
            guard let der = Data(base64Encoded: base64) else {
                throw VaultConfigurationError.invalidPin
            }
            return .pinnedLeafDER(der)
        }
    }
}

/// TLS member union: the string `"system"` or a pinned-leaf object.
private enum VaultTLSMember: Decodable {
    case system
    case pinned(String)

    init(from decoder: Decoder) throws {
        if let label = try? decoder.singleValueContainer().decode(String.self) {
            guard label == "system" else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unknown tls mode"
                )
            }
            self = .system
            return
        }
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["pinnedLeafDER"])
        self = .pinned(
            try container.decode(String.self, forKey: StrictJSONKey("pinnedLeafDER"))
        )
    }
}

/// Versioned endpoint config document. Closed key set: unknown members
/// fail closed, so a misunderstood security-critical field can never
/// slip through. Only `endpoint` is required.
private struct VaultEndpointDocument: Decodable {
    let version: Int
    let endpoint: String
    let mount: String?
    let tls: VaultTLSMember?
    let timeoutSeconds: Double?
    let wrapTTL: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container,
            allowed: ["version", "endpoint", "mount", "tls", "timeoutSeconds", "wrapTTL"]
        )
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        endpoint = try container.decode(String.self, forKey: StrictJSONKey("endpoint"))
        mount = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("mount"))
        tls = try container.decodeIfPresent(VaultTLSMember.self, forKey: StrictJSONKey("tls"))
        timeoutSeconds = try container.decodeIfPresent(
            Double.self, forKey: StrictJSONKey("timeoutSeconds")
        )
        wrapTTL = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("wrapTTL"))
    }
}

// MARK: - Factory

/// Production provider construction (E1-A).
///
/// Pure construction: the only IO is owner-only config loads, and every
/// load error fails closed with zero providers plus a labels-only
/// `SecretsProviderFactoryError` — secret material never flows into
/// thrown errors.
///
/// Construction rule: file plus keychain plus env always (keychain via
/// `currentPlatform`, so Linux omits it fail-closed per CON-003 with no
/// fallback), and a `VaultHTTPClient` if and only if `vault.json` is
/// present and valid, with AppRole credentials from `VaultAppRoleStore`.
/// `secrets-providers.json` must load cleanly but does not gate
/// construction: the broker prechecks registration and healths only
/// involved providers per call, so unreferenced providers cost nothing,
/// while bindings stay the ref-naming layer consumed at admission
/// (E1-C). A corrupt bindings file still fails the factory: serving
/// secrets from a half-understood operator config is never acceptable.
///
/// E1-A adds no production callers: E1-C wires `makeBroker` into the
/// supervisor preparation path.
public enum SecretsProviderFactory {
    /// Builds the production provider set from `configDirectory`.
    ///
    /// - `transport`: stub HTTP round trip for tests. Nil builds a live
    ///   URLSession client; non-nil builds over the injected stub with
    ///   the same validation (the mockable transport seam).
    /// - `tracker`: lease tracker for stub-transport clients. Honored
    ///   only alongside an injected transport; live clients own a
    ///   default-policy tracker internally.
    ///
    /// Throws the labels-only cause with zero providers on any config
    /// failure. Never throws secret material.
    public static func makeProviders(
        configDirectory: URL,
        transport: (
            @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        )? = nil,
        tracker: VaultLeaseTracker? = nil,
        environment: [String: String]? = nil
    ) throws(SecretsProviderFactoryError) -> [any SecretsProvider] {
        switch SecretsProviderStore.load(from: configDirectory) {
        case .success:
            break
        case .failure:
            throw SecretsProviderFactoryError.providersInvalid
        }
        var providers: [any SecretsProvider] = [
            FileSecretsProvider(configDirectory: configDirectory)
        ]
        if let keychain = KeychainSecretsProvider.currentPlatform() {
            providers.append(keychain)
        }
        providers.append(EnvSecretsProvider())
        switch VaultEndpointStore.load(from: configDirectory) {
        case .success(nil):
            break
        case .success(let config?):
            providers.append(
                try vaultClient(
                    config: config, configDirectory: configDirectory,
                    transport: transport, tracker: tracker
                )
            )
        case .failure(let error):
            throw error
        }
        // X1-E: opt-in like Vault's absent-config skip. A loadable master
        // key (EXECUTOR_SECRET_KEY, else owner-only secret.key) appends the
        // encrypted provider; no key means no provider, and refs to it deny
        // `.providerDown` fail-closed at the broker. `defaultOwner` is `.org`:
        // RV is single-tenant, so every broker resolve is org-level.
        let masterKeyEnvironment = environment ?? ProcessInfo.processInfo.environment
        if let masterKey = EncryptedSecretsProvider.loadMasterKey(
            environment: masterKeyEnvironment, keyFileDirectory: configDirectory
        ),
            let encrypted = try? EncryptedSecretsProvider(
                configDirectory: configDirectory, masterKey: masterKey, defaultOwner: .org
            )
        {
            providers.append(encrypted)
        }
        return providers
    }

    /// Builds a production `SecretBroker` over the factory provider set.
    ///
    /// Same construction as `makeProviders`, wired to the caller's audit
    /// sink and liveness check. E1-C passes the ledger-backed sink and
    /// the registry-backed liveness; tests pass captures and scripted
    /// checks. This is the `(configDirectory:audit:liveness:)` wiring
    /// the ticket names, split from provider construction so each half
    /// keeps a coherent signature: providers take no audit or liveness.
    public static func makeBroker(
        configDirectory: URL,
        audit: SecretBrokerAuditSink,
        liveness: SecretBrokerLiveness,
        timeoutSeconds: Double = 5,
        transport: (
            @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        )? = nil,
        tracker: VaultLeaseTracker? = nil,
        environment: [String: String]? = nil
    ) throws(SecretsProviderFactoryError) -> SecretBroker {
        let providers = try makeProviders(
            configDirectory: configDirectory, transport: transport, tracker: tracker,
            environment: environment
        )
        return SecretBroker(
            providers: providers, audit: audit,
            liveness: liveness, timeoutSeconds: timeoutSeconds
        )
    }

    /// Builds one Vault client: AppRole credentials via the owner-only
    /// approle store, then the live or stub-transport init.
    private static func vaultClient(
        config: VaultEndpointConfig,
        configDirectory: URL,
        transport: (
            @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        )?,
        tracker: VaultLeaseTracker?
    ) throws(SecretsProviderFactoryError) -> VaultHTTPClient {
        let auth: VaultHTTPAuth
        switch VaultAppRoleStore.load(from: configDirectory) {
        case .success(let loaded):
            auth = loaded
        case .failure:
            throw SecretsProviderFactoryError.vaultCredentialsInvalid
        }
        do {
            if let transport {
                return try VaultHTTPClient(
                    endpoint: config.endpoint, mount: config.mount,
                    auth: auth, tls: config.tls,
                    timeoutSeconds: config.timeoutSeconds,
                    transport: transport, wrapTTL: config.wrapTTL,
                    tracker: tracker
                )
            }
            return try VaultHTTPClient(
                endpoint: config.endpoint, mount: config.mount,
                auth: auth, tls: config.tls,
                timeoutSeconds: config.timeoutSeconds,
                wrapTTL: config.wrapTTL
            )
        } catch {
            throw SecretsProviderFactoryError.vaultMisconfigured
        }
    }

}
