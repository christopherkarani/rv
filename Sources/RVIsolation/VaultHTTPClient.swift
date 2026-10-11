import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import RVDomain
import RVFileStore

/// Semantic Vault server version (major.minor.patch).
///
/// Pre-release and build suffixes (`-beta1`, `+ent`) and a leading `v` are
/// ignored: `v1.15.0+ent` parses as 1.15.0. Two-part versions (`1.15`)
/// default the patch to zero. Anything else fails closed as nil.
public struct VaultVersion: Sendable, Equatable, Comparable, Hashable, CustomStringConvertible {
    /// Major release number.
    public let major: Int
    /// Minor release number.
    public let minor: Int
    /// Patch release number.
    public let patch: Int

    /// Assembles a version from numeric parts.
    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Minimum server VaultHTTPClient talks to, pinned by T6a.
    ///
    /// 1.15.0 is the floor: KV-v2, AppRole, and the `sys/health` version
    /// field are all long stable there. Older or unparsable servers fail
    /// closed as `providerDown("vault-http:version")`.
    public static let minimum = VaultVersion(major: 1, minor: 15, patch: 0)

    /// Parses a Vault `version` string, or nil when unparsable.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let noV: String
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            noV = String(trimmed.dropFirst())
        } else {
            noV = trimmed
        }
        guard noV.first?.isNumber == true else { return nil }
        let core = noV.split(whereSeparator: { $0 == "+" || $0 == "-" }).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        let patch: Int
        if parts.count == 3 {
            guard let parsed = Int(parts[2]) else { return nil }
            patch = parsed
        } else {
            patch = 0
        }
        guard major >= 0 && minor >= 0 && patch >= 0 else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// Dotted form (`1.15.0`).
    public var description: String { "\(major).\(minor).\(patch)" }

    /// Lexicographic order over major, minor, patch.
    public static func < (left: VaultVersion, right: VaultVersion) -> Bool {
        if left.major != right.major { return left.major < right.major }
        if left.minor != right.minor { return left.minor < right.minor }
        return left.patch < right.patch
    }
}

/// TLS trust for Vault HTTPS: system CA or an exact pinned leaf.
///
/// System uses the platform trust store with no override. Pinned compares
/// the served leaf certificate DER bytes for exact equality: no hash, no
/// Crypto dependency, no silent downgrade. Pinned enforcement lives in the
/// live URLSession delegate on macOS; the pure `matches(_:)` below is the
/// tested comparison kernel shared by both.
public enum VaultTLSConfig: Sendable, Equatable {
    /// Platform trust store, no override.
    case system
    /// Exact expected leaf certificate DER bytes.
    case pinnedLeafDER(Data)

    /// Largest pinned leaf accepted (16 KiB; real DER is 0.5-2 KiB).
    public static let maximumPinnedBytes = 16_384
    /// Smallest pinned leaf accepted (128 bytes; smaller cannot be a cert).
    public static let minimumPinnedBytes = 128

    /// True when `leafDER` satisfies the config.
    ///
    /// System always returns true: the platform validates and there is no
    /// pin to check. Pinned returns exact equality. Certificates are
    /// public, so a timing side channel here leaks nothing.
    public func matches(leafDER: Data) -> Bool {
        switch self {
        case .system:
            true
        case .pinnedLeafDER(let pinned):
            leafDER == pinned
        }
    }
}

/// Vault authentication: direct token or AppRole machine credentials.
///
/// Tokens and AppRole secrets are secret material: they travel in headers
/// and bodies only, never in URLs, errors, or logs. `label` is the only
/// log-safe projection.
public enum VaultHTTPAuth: Sendable, Equatable {
    /// Direct `X-Vault-Token` value, provisioned by the operator.
    case token(String)
    /// AppRole login pair, loaded from owner-only storage.
    case appRole(roleID: String, secretID: String)

    /// Labels-only auth kind (`token` or `approle`). Never the credential.
    public var label: String {
        switch self {
        case .token:
            "token"
        case .appRole:
            "approle"
        }
    }
}

/// Vault client misconfiguration. All cases carry no payload: fixed labels
/// only, never endpoints, mounts, or credentials.
public enum VaultConfigurationError: Error, Sendable, Equatable {
    /// Endpoint is not an http(s) URL with a host and empty path.
    case invalidEndpoint
    /// Plain http targets a non-loopback host.
    case httpNotAllowedForNonLoopback
    /// Mount is empty or outside `[A-Za-z0-9_-]` segments.
    case invalidMount
    /// Token auth carries an empty token.
    case emptyToken
    /// AppRole carries an empty role id.
    case emptyRoleID
    /// AppRole carries an empty secret id.
    case emptySecretID
    /// Pinned leaf is empty or outside 128 bytes through 16 KiB.
    case invalidPin
    /// Timeout is nonpositive, nonfinite, or above 60 seconds.
    case invalidTimeout
    /// Wrap TTL is not a positive `<number><s|m|h>` duration.
    case invalidWrapTTL
    /// Pinned TLS has no enforcement hook on this platform (Linux live).
    case pinningUnavailable
}

/// AppRole credential load failure. Fixed labels only, never ids.
public enum VaultCredentialError: Error, Sendable, Equatable {
    /// Directory or file failed the owner-only, no-symlink checks.
    case unsafeLocation
    /// File could not be read.
    case unreadable
    /// File exceeds the size cap.
    case oversized
    /// File is not a strict v1 approle document with usable ids.
    case invalidDocument
    /// Document version is not 1.
    case unsupportedVersion
}

/// Loads AppRole credentials from owner-only `vault-approle.json`.
///
/// Document shape: `{"version":1,"role_id":"...","secret_id":"..."}` with a
/// closed key set. The directory must be owner-owned without group or other
/// write; the file must be a regular owner-only 0600 file reached without
/// following symlinks; the document is capped at 4 KiB and each id at 2 KiB.
/// Missing files fail closed as `.unreadable`: AppRole has no empty default.
/// Decoded ids are trimmed of surrounding whitespace and must be non-empty.
public enum VaultAppRoleStore {
    /// Credentials file name beside the sibling operator stores.
    public static let fileName = "vault-approle.json"
    /// Largest credentials document accepted.
    public static let maximumBytes = 4_096
    /// Largest single id accepted after trimming.
    public static let maximumIDBytes = 2_048

    /// Loads credentials from `fileName` under `configDirectory`.
    /// Missing files fail closed as `.unreadable`: AppRole has no empty default.
    public static func load(from configDirectory: URL) -> Result<VaultHTTPAuth, VaultCredentialError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data)
        case .failure(.missing), .failure(.inaccessible):
            return .failure(.unreadable)
        case .failure(.unsafeLocation):
            return .failure(.unsafeLocation)
        case .failure(.unreadable):
            return .failure(.unreadable)
        case .failure(.oversized):
            return .failure(.oversized)
        }
    }

    /// Decodes one credentials document. Strict keys, version 1, trimmed
    /// non-empty ids capped at 2 KiB each.
    public static func decode(_ data: Data) -> Result<VaultHTTPAuth, VaultCredentialError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(VaultAppRoleDocument.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        let role = document.roleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = document.secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role.isEmpty == false, secret.isEmpty == false,
            role.utf8.count <= maximumIDBytes, secret.utf8.count <= maximumIDBytes
        else {
            return .failure(.invalidDocument)
        }
        return .success(.appRole(roleID: role, secretID: secret))
    }
}

/// Temporary alias: tests pin the historical name; new code uses `StrictJSONKey`.
typealias VaultAppRoleKey = StrictJSONKey

/// Versioned approle document: role and secret ids only, never tokens.
private struct VaultAppRoleDocument: Decodable {
    let version: Int
    let roleID: String
    let secretID: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "role_id", "secret_id"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        roleID = try container.decode(String.self, forKey: StrictJSONKey("role_id"))
        secretID = try container.decode(String.self, forKey: StrictJSONKey("secret_id"))
    }
}

// MARK: - Leases (T6b)

/// Clock source for lease expiry. Production uses `Date.init`; tests inject
/// a mutable box to time-travel deterministically.
public typealias VaultClock = @Sendable () -> Date

/// Jitter draw in [-1, 1] for renewal scheduling. Production passes a random
/// draw; tests inject fixed values. Out-of-range draws clamp, never trap.
public typealias VaultJitterSource = @Sendable () -> Double

/// Renewal scheduling policy: bounded cardinality, bounded duration,
/// plus jitter (T0d).
public struct VaultLeasePolicy: Sendable, Equatable {
    /// Default cap on tracked leases.
    public static let defaultMaxTrackedLeases = 64
    /// Default fraction of the TTL after which a lease becomes due.
    public static let defaultRenewFraction = 0.5
    /// Default maximum jitter as a fraction of the base renew delay.
    public static let defaultMaxJitterFraction = 0.1
    /// Default cap on one lease duration (24 hours). Server-provided
    /// durations clamp to this so one rogue response cannot pin a
    /// stale secret ~forever.
    public static let defaultMaximumLeaseDurationSeconds = 86_400

    /// Largest number of leases held. At cap, expired entries are evicted
    /// first; a new lease beyond cap is served once but not tracked.
    public let maxTrackedLeases: Int
    /// Fraction of the TTL after which a renewable lease becomes due.
    public let renewFraction: Double
    /// Jitter band around the base renew delay, as a fraction of it.
    public let maxJitterFraction: Double
    /// Longest single lease duration honored. Longer server-provided
    /// durations clamp to this at track and renew time.
    public let maximumLeaseDurationSeconds: Int

    public init(
        maxTrackedLeases: Int = defaultMaxTrackedLeases,
        renewFraction: Double = defaultRenewFraction,
        maxJitterFraction: Double = defaultMaxJitterFraction,
        maximumLeaseDurationSeconds: Int = defaultMaximumLeaseDurationSeconds
    ) {
        self.maxTrackedLeases = max(1, maxTrackedLeases)
        self.renewFraction = min(max(renewFraction, 0), 1)
        self.maxJitterFraction = min(max(maxJitterFraction, 0), 1)
        self.maximumLeaseDurationSeconds = max(1, maximumLeaseDurationSeconds)
    }

    /// Delay from tracking until a lease becomes due for renewal.
    ///
    /// `base = duration * renewFraction`, then `base * (1 + jitterUnit *
    /// maxJitterFraction)`. The jitter unit clamps to [-1, 1] and the
    /// result to [0, duration]; nonpositive durations renew immediately.
    public func renewDelay(leaseDurationSeconds duration: Int, jitterUnit: Double) -> Double {
        guard duration > 0 else { return 0 }
        let unit = min(max(jitterUnit, -1), 1)
        let base = Double(duration) * renewFraction
        let delayed = base * (1 + unit * maxJitterFraction)
        return min(max(delayed, 0), Double(duration))
    }
}

/// One tracked dynamic lease plus its cached value.
///
/// `leaseID` is an opaque Vault handle: it authorizes renewal of this lease
/// only, and this module never logs it.
public struct VaultLease: Sendable, Equatable {
    public let leaseID: String
    public let renewable: Bool
    public let leaseDuration: Int
    public let refKey: String
    public let value: SecretValue
    public let trackedAt: Date
    public let renewsAt: Date
    public let expiresAt: Date

    /// True once wall-clock expiry is reached. Expired values are never served.
    public func isExpired(now: Date) -> Bool { now >= expiresAt }

    /// True when renewable, past the jittered renew time, and not yet expired.
    public func isDue(now: Date) -> Bool { renewable && now >= renewsAt && now < expiresAt }
}

/// Cache lookup outcome for one ref key.
public enum VaultCacheLookup: Sendable, Equatable {
    /// Live lease held: serve without network.
    case hit(SecretValue)
    /// Lease expired: the entry is consumed; the next lookup misses.
    case expired
    /// Nothing tracked: perform a fresh read.
    case miss
}

/// Actor holding live leases. One tracker per client; struct copies of a
/// client share it, so expiry and renewal are coherent across copies.
public actor VaultLeaseTracker {
    private let policy: VaultLeasePolicy
    private let clock: VaultClock
    private let jitter: VaultJitterSource
    private var leases: [String: VaultLease] = [:]

    public init(
        policy: VaultLeasePolicy = VaultLeasePolicy(),
        clock: VaultClock? = nil,
        jitter: VaultJitterSource? = nil
    ) {
        self.policy = policy
        self.clock = clock ?? { Date() }
        self.jitter = jitter ?? { Double.random(in: -1...1) }
    }

    /// Cached value for one ref key. An expired entry is consumed (removed)
    /// and reported once as `.expired`; the next lookup misses and the
    /// client performs a fresh read.
    public func cachedValue(forKey key: String) -> VaultCacheLookup {
        guard let lease = leases[key] else { return .miss }
        if lease.isExpired(now: clock()) {
            leases.removeValue(forKey: key)
            return .expired
        }
        return .hit(lease.value)
    }

    /// Tracks a lease read from Vault. Returns false without tracking when
    /// the lease is unusable (empty id, nonpositive duration) or the store
    /// is at cap after evicting expired entries. Retracking one ref key
    /// replaces the previous entry. The duration clamps to the policy
    /// maximum so one rogue response cannot pin a stale secret ~forever.
    @discardableResult
    public func track(
        refKey: String, value: SecretValue, leaseID: String,
        renewable: Bool, leaseDuration: Int
    ) -> Bool {
        guard leaseID.isEmpty == false, leaseDuration > 0 else { return false }
        let clamped = min(leaseDuration, policy.maximumLeaseDurationSeconds)
        let now = clock()
        if leases[refKey] == nil, leases.count >= policy.maxTrackedLeases {
            evictExpired(now: now)
            guard leases.count < policy.maxTrackedLeases else { return false }
        }
        let delay = policy.renewDelay(leaseDurationSeconds: clamped, jitterUnit: jitter())
        leases[refKey] = VaultLease(
            leaseID: leaseID, renewable: renewable, leaseDuration: clamped,
            refKey: refKey, value: value, trackedAt: now,
            renewsAt: now.addingTimeInterval(delay),
            expiresAt: now.addingTimeInterval(Double(clamped))
        )
        return true
    }

    /// Renewable leases due for renewal and not yet expired, oldest-due first.
    public func dueLeases() -> [VaultLease] {
        let now = clock()
        return leases.values.filter { $0.isDue(now: now) }.sorted { $0.renewsAt < $1.renewsAt }
    }

    /// Records a successful renewal: new duration, new expiry, fresh jitter.
    /// Returns the updated lease, or nil when the id is no longer tracked.
    /// The renewed duration clamps to the policy maximum, like `track`.
    @discardableResult
    public func didRenew(leaseID: String, renewable: Bool, leaseDuration: Int) -> VaultLease? {
        guard leaseDuration > 0,
            let key = leases.first(where: { $0.value.leaseID == leaseID })?.key,
            let current = leases[key]
        else {
            return nil
        }
        let clamped = min(leaseDuration, policy.maximumLeaseDurationSeconds)
        let now = clock()
        let delay = policy.renewDelay(leaseDurationSeconds: clamped, jitterUnit: jitter())
        let updated = VaultLease(
            leaseID: current.leaseID, renewable: renewable, leaseDuration: clamped,
            refKey: current.refKey, value: current.value, trackedAt: now,
            renewsAt: now.addingTimeInterval(delay),
            expiresAt: now.addingTimeInterval(Double(clamped))
        )
        leases[key] = updated
        return updated
    }

    /// Stops tracking one lease id. The next resolve for its ref re-reads fresh.
    public func drop(leaseID: String) {
        if let key = leases.first(where: { $0.value.leaseID == leaseID })?.key {
            leases.removeValue(forKey: key)
        }
    }

    /// Number of tracked leases, including expired tombstones.
    public var leaseCount: Int { leases.count }

    /// Sorted tracked lease ids, for inspection. Handles, never logged.
    public func trackedLeaseIDs() -> [String] { leases.values.map(\.leaseID).sorted() }

    /// Entry for one ref key, if tracked.
    public func lease(forKey key: String) -> VaultLease? { leases[key] }

    private func evictExpired(now: Date) {
        leases = leases.filter { $0.value.isExpired(now: now) == false }
    }
}

/// Outcome of one lease renewal attempt.
public struct VaultLeaseRenewal: Sendable, Equatable {
    /// Renewed lease id. An opaque handle, never logged by this module.
    public let leaseID: String
    public let outcome: Outcome

    public init(leaseID: String, outcome: Outcome) {
        self.leaseID = leaseID
        self.outcome = outcome
    }

    public enum Outcome: Sendable, Equatable {
        /// Renewed: fresh expiry and duration from Vault.
        case renewed(expiresAt: Date, leaseDuration: Int)
        /// Not renewed: mapped cause, labels only. The lease is kept for
        /// retry except after definitive rejection, which reports
        /// `.leaseExpired` and drops the lease.
        case failed(SecretsError)
    }
}

/// One HTTP round trip: request to response body plus status.
///
/// Production wraps a URLSession; tests inject a stub-session closure so
/// every test runs deterministically with no network.
typealias VaultTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Vault KV-v2 secrets provider over HTTPS (REQ-004, T6a reads plus T6b leases).
///
/// Speaks the `api/client.go` shape: `X-Vault-Token` auth, AppRole login,
/// KV-v2 paths, `sys/health` gating, `PUT /v1/sys/leases/renew` renewal,
/// and `X-Vault-Wrap-TTL` wrapping with `PUT /v1/sys/wrapping/unwrap`.
/// KV lease fields are honored: leased values are cached until expiry,
/// renewable leases renew via `renewDueLeases` (driven by
/// `runRenewalLoop`), and expired leases throw `.leaseExpired` without
/// ever serving stale values.
///
/// Fail-closed mapping (T0d): sealed, uninitialized, forbidden (403/401),
/// rate-limited (429), standby (health standby, 307, 472/473), unreachable,
/// TLS, version, auth, decode, and server failures all throw
/// `SecretsError.providerDown` with distinct `vault-http:<cause>` labels;
/// timeouts throw `SecretsError.timeout`; missing secrets throw
/// `.notFound`; bad refs throw `.invalidRef`; oversized bodies throw
/// `.oversized`. Renewal and unwrap reuse the same causes; wrap-mechanism
/// failures (missing wrapping token, rejected unwrap) throw
/// `providerDown("vault-http:wrap")`; definitively rejected leases surface
/// `.leaseExpired`; wall-clock expiry throws `.leaseExpired` and consumes
/// the entry, so a later resolve re-reads fresh. Labels name the provider
/// and cause only: tokens, ids, items, fields, and values never appear in
/// errors, URLs, or logs.
///
/// No silent fallback: token auth never attempts AppRole login, AppRole
/// failure never retries as token, and Vault failure never consults
/// another provider. Uncached resolves re-validate health (seal, init,
/// version) with no caching: a seal between calls fails the next uncached
/// call. Held unexpired leases are served from the tracker without
/// network, so they stay usable while sealed, until expiry.
public struct VaultHTTPClient: SecretsProvider, Sendable {
    /// Provider id. Always a member of `SecretRef.allowedProviders`.
    public var id: String { "vault-http" }

    /// Vault base URL (scheme, host, port only; no path, query, or userinfo).
    public let endpoint: URL
    /// KV-v2 mount (default `secret`).
    public let mount: String
    /// Token or AppRole credentials. Secret material, never logged.
    public let auth: VaultHTTPAuth
    /// System CA or pinned leaf.
    public let tls: VaultTLSConfig
    /// Per-request timeout in seconds.
    public let timeoutSeconds: Double
    /// Response-wrapping TTL (`30s`, `5m`, `1h`) sent as
    /// `X-Vault-Wrap-TTL` on KV reads, or nil for direct reads.
    public let wrapTTL: String?

    private let transport: VaultTransport
    private let tracker: VaultLeaseTracker

    /// Minimum server version accepted, pinned by T6a: 1.15.0.
    public static let minimumVersion = VaultVersion.minimum
    /// Largest AppRole token TTL accepted (1 hour). Longer mints fail as auth.
    public static let maximumTokenTTLSeconds = 3_600
    /// Largest single HTTP body accepted (1 MiB). Larger fails as oversized.
    public static let maximumResponseBytes = 1_048_576
    /// Default KV-v2 mount.
    public static let defaultMount = "secret"
    /// Default per-request timeout.
    public static let defaultTimeoutSeconds = 10.0

    /// Live client over URLSession (system CA, or pinned on macOS).
    ///
    /// Validates endpoint, mount, auth, TLS, and timeout before returning.
    /// Pinned TLS on Linux throws `.pinningUnavailable`: there is no
    /// enforcement hook, so live pinned connections fail closed at init
    /// rather than silently downgrading to system trust.
    public init(
        endpoint: URL,
        mount: String = VaultHTTPClient.defaultMount,
        auth: VaultHTTPAuth,
        tls: VaultTLSConfig = .system,
        timeoutSeconds: Double = VaultHTTPClient.defaultTimeoutSeconds,
        wrapTTL: String? = nil,
        leasePolicy: VaultLeasePolicy = VaultLeasePolicy()
    ) throws(VaultConfigurationError) {
        try Self.validate(endpoint: endpoint)
        try Self.validate(mount: mount)
        try Self.validate(auth: auth)
        try Self.validate(tls: tls)
        try Self.validate(timeoutSeconds: timeoutSeconds)
        try Self.validate(wrapTTL: wrapTTL)
#if os(macOS)
        let transport = Self.liveTransport(tls: tls)
#else
        if case .pinnedLeafDER = tls {
            throw VaultConfigurationError.pinningUnavailable
        }
        let transport = Self.liveTransport(tls: tls)
#endif
        self.endpoint = endpoint
        self.mount = mount
        self.auth = auth
        self.tls = tls
        self.timeoutSeconds = timeoutSeconds
        self.wrapTTL = wrapTTL
        self.transport = transport
        self.tracker = VaultLeaseTracker(policy: leasePolicy)
    }

    /// Test client over an injected stub transport. Same validation as the
    /// live init, except pinned TLS is stored without a platform
    /// enforcement check: the stub never performs a handshake.
    init(
        endpoint: URL,
        mount: String,
        auth: VaultHTTPAuth,
        tls: VaultTLSConfig,
        timeoutSeconds: Double,
        transport: @escaping VaultTransport,
        wrapTTL: String? = nil,
        tracker: VaultLeaseTracker? = nil
    ) throws(VaultConfigurationError) {
        try Self.validate(endpoint: endpoint)
        try Self.validate(mount: mount)
        try Self.validate(auth: auth)
        try Self.validate(tls: tls)
        try Self.validate(timeoutSeconds: timeoutSeconds)
        try Self.validate(wrapTTL: wrapTTL)
        self.endpoint = endpoint
        self.mount = mount
        self.auth = auth
        self.tls = tls
        self.timeoutSeconds = timeoutSeconds
        self.wrapTTL = wrapTTL
        self.transport = transport
        self.tracker = tracker ?? VaultLeaseTracker()
    }

    /// Resolves one vault-http ref through cache, health, auth, then KV-v2.
    ///
    /// Ordering: provider check, item encoding check, lease-cache check
    /// (hit serves without network; expired throws `.leaseExpired` and
    /// consumes the entry), `sys/health` gate (seal, init, standby,
    /// version), AppRole login when configured, then the KV-v2 read with
    /// lease honor and optional wrap-TTL unwrap. No fallback. Task
    /// cancellation propagates as `CancellationError` without mapping.
    public func resolve(_ ref: SecretRef) async throws -> SecretValue {
        guard ref.provider == id else {
            throw SecretsError.invalidRef(id)
        }
        let path = try Self.kvPath(mount: mount, item: ref.item)
        let key = Self.refKey(item: ref.item, field: ref.field)
        switch await tracker.cachedValue(forKey: key) {
        case .hit(let value):
            return value
        case .expired:
            throw SecretsError.leaseExpired(id)
        case .miss:
            break
        }
        try await precheck()
        let token = try await loginToken()
        return try await kvRead(path: path, token: token, field: ref.field, refKey: key)
    }

    /// Reachable when `sys/health` reports an active unsealed initialized
    /// server at or above the minimum version. Never throws: every failure
    /// (including cancellation) reports unhealthy. Identity is always nil:
    /// Vault identities are per-login accessors, and health is
    /// unauthenticated by design.
    public func health() async -> ProviderHealth {
        do {
            let url = joining("/v1/sys/health")
            let (data, response) = try await transport(get(url: url))
            guard data.count <= Self.maximumResponseBytes else {
                return ProviderHealth(ok: false)
            }
            return ProviderHealth(ok: Self.healthOK(status: response.statusCode, body: data))
        } catch {
            return ProviderHealth(ok: false)
        }
    }
}

// MARK: - Validation

extension VaultHTTPClient {
    static func validate(endpoint: URL) throws(VaultConfigurationError) {
        guard let scheme = endpoint.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = endpoint.host, host.isEmpty == false,
            endpoint.user == nil, endpoint.password == nil,
            endpoint.query == nil, endpoint.fragment == nil,
            endpoint.path.isEmpty || endpoint.path == "/"
        else {
            throw VaultConfigurationError.invalidEndpoint
        }
        if scheme == "http" {
            let loopback = host.lowercased() == "127.0.0.1"
                || host.lowercased() == "localhost"
                || host == "::1"
                || host == "[::1]"
            if loopback == false {
                throw VaultConfigurationError.httpNotAllowedForNonLoopback
            }
        }
    }

    static func validate(mount: String) throws(VaultConfigurationError) {
        guard mount.isEmpty == false, mount.hasPrefix("/") == false, mount.hasSuffix("/") == false,
            mount.contains("\0") == false, mount.contains("\n") == false, mount.contains("\r") == false
        else {
            throw VaultConfigurationError.invalidMount
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        for segment in mount.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            guard segment.isEmpty == false, segment != ".", segment != "..",
                segment.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else {
                throw VaultConfigurationError.invalidMount
            }
        }
    }

    static func validate(auth: VaultHTTPAuth) throws(VaultConfigurationError) {
        switch auth {
        case .token(let value):
            if value.isEmpty { throw VaultConfigurationError.emptyToken }
        case .appRole(let roleID, let secretID):
            if roleID.isEmpty { throw VaultConfigurationError.emptyRoleID }
            if secretID.isEmpty { throw VaultConfigurationError.emptySecretID }
        }
    }

    static func validate(tls: VaultTLSConfig) throws(VaultConfigurationError) {
        switch tls {
        case .system:
            return
        case .pinnedLeafDER(let data):
            guard data.count >= VaultTLSConfig.minimumPinnedBytes,
                data.count <= VaultTLSConfig.maximumPinnedBytes
            else {
                throw VaultConfigurationError.invalidPin
            }
        }
    }

    static func validate(timeoutSeconds: Double) throws(VaultConfigurationError) {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60 else {
            throw VaultConfigurationError.invalidTimeout
        }
    }

    static func validate(wrapTTL: String?) throws(VaultConfigurationError) {
        guard let wrapTTL else { return }
        guard wrapTTL.count >= 2, wrapTTL.count <= 6,
            let unit = wrapTTL.last, unit == "s" || unit == "m" || unit == "h",
            let value = Int(wrapTTL.dropLast()), value >= 1
        else {
            throw VaultConfigurationError.invalidWrapTTL
        }
    }

    /// Cache key for one ref: length-prefixed item plus field, so no
    /// (item, field) pair collides with another.
    static func refKey(item: String, field: String?) -> String {
        "\(item.count):\(item)\u{1F}\(field ?? "")"
    }

    /// KV-v2 path for one item: `/v1/<mount>/data/<segments>`.
    ///
    /// Each slash-separated segment is percent-encoded as one unit, so `/`
    /// stays a separator and nothing else can smuggle one. NUL, empty
    /// segments (double slashes), and `.`/`..` segments fail closed: the
    /// first cannot form a URL and the rest would normalize away from the
    /// addressed secret. Dots inside longer names (`my.tool.v2`) pass
    /// through: only exact `.`/`..` normalize.
    static func kvPath(mount: String, item: String) throws(SecretsError) -> String {
        guard item.contains("\0") == false else {
            throw SecretsError.invalidRef("vault-http")
        }
        var trimmed = item
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") && trimmed.isEmpty == false { trimmed.removeLast() }
        guard trimmed.isEmpty == false else {
            throw SecretsError.invalidRef("vault-http")
        }
        let raw = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var encoded: [String] = []
        encoded.reserveCapacity(raw.count)
        for segment in raw {
            guard segment.isEmpty == false, segment != ".", segment != ".." else {
                throw SecretsError.invalidRef("vault-http")
            }
            guard let one = segment.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw SecretsError.invalidRef("vault-http")
            }
            encoded.append(one)
        }
        return "/v1/\(mount)/data/\(encoded.joined(separator: "/"))"
    }
}

// MARK: - Requests and transport

extension VaultHTTPClient {
    /// Shared system-trust session. Redirects are refused by the
    /// delegate, so tokens and AppRole bodies never follow a 3xx
    /// off-origin; sharing keeps keep-alive across resolves.
    private static let systemSession = URLSession(
        configuration: .ephemeral, delegate: VaultNoRedirectDelegate(), delegateQueue: nil
    )

    static func liveTransport(tls: VaultTLSConfig) -> VaultTransport {
        switch tls {
        case .system:
            return { request in
                let (data, response) = try await Self.systemSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                return (data, http)
            }
        case .pinnedLeafDER(let pinned):
#if os(macOS)
            let delegate = VaultPinningDelegate(pinned: pinned)
            let session = URLSession(
                configuration: .ephemeral, delegate: delegate, delegateQueue: nil
            )
            return { [session] request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                return (data, http)
            }
#else
            _ = pinned
            return { _ in
                throw URLError(.secureConnectionFailed)
            }
#endif
        }
    }

    func joining(_ path: String) -> URL {
        var base = endpoint.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? endpoint
    }

    func get(url: URL) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    func postJSON(url: URL, body: Data) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.httpShouldHandleCookies = false
        return request
    }

    func authedGet(url: URL, token: String) -> URLRequest {
        var request = get(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Vault-Token")
        return request
    }

    /// Authenticated PUT with a JSON body (renew, unwrap).
    func putJSON(url: URL, token: String, body: Data) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Vault-Token")
        request.httpBody = body
        request.httpShouldHandleCookies = false
        return request
    }
}

// MARK: - Resolve phases

extension VaultHTTPClient {
    /// Sends one request: transport errors map (a thrown `SecretsError`
    /// passes through, cancellation rethrows, anything else maps), and an
    /// over-cap body fails as oversized. The five call sites shared this
    /// block verbatim.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: Data
        let response: HTTPURLResponse
        do {
            let (data, raw) = try await transport(request)
            body = data
            response = raw
        } catch let error as SecretsError {
            throw error
        } catch {
            if error is CancellationError {
                throw error
            }
            throw Self.mapTransportError(error)
        }
        guard body.count <= Self.maximumResponseBytes else {
            throw SecretsError.oversized("vault-http")
        }
        return (body, response)
    }

    /// Unauthenticated `sys/health` gate. Throws the distinct down cause;
    /// returns only for an active unsealed initialized server at or above
    /// the minimum version.
    func precheck() async throws -> Void {
        let url = joining("/v1/sys/health")
        let (body, response) = try await send(get(url: url))
        let status = response.statusCode
        try Self.throwIfHealthDown(status: status, body: body)
    }

    /// Client token for one operation: direct for token auth, freshly
    /// minted for AppRole. Shared by resolve and renewal cycles.
    func loginToken() async throws -> String {
        switch auth {
        case .token(let value):
            return value
        case .appRole(let roleID, let secretID):
            return try await login(roleID: roleID, secretID: secretID)
        }
    }

    /// AppRole login returning a short-lived client token.
    ///
    /// Requires a non-empty token, a non-empty accessor, and a TTL in
    /// 1 through 3,600 seconds. Anything else fails as auth: no token is
    /// returned and no KV request follows.
    func login(roleID: String, secretID: String) async throws -> String {
        let url = joining("/v1/auth/approle/login")
        let payload = VaultLoginRequest(roleID: roleID, secretID: secretID)
        guard let encoded = try? JSONEncoder().encode(payload) else {
            throw SecretsError.providerDown("vault-http:decode")
        }
        let (body, response) = try await send(postJSON(url: url, body: encoded))
        let status = response.statusCode
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(VaultLoginResponse.self, from: body),
                let auth = decoded.auth,
                auth.clientToken.isEmpty == false,
                auth.accessor.isEmpty == false,
                auth.leaseDuration >= 1,
                auth.leaseDuration <= Self.maximumTokenTTLSeconds
            else {
                throw SecretsError.providerDown("vault-http:auth")
            }
            return auth.clientToken
        case 400, 404:
            throw SecretsError.providerDown("vault-http:auth")
        case 401, 403:
            throw SecretsError.providerDown("vault-http:forbidden")
        case 429:
            throw SecretsError.providerDown("vault-http:rateLimited")
        case 501:
            throw SecretsError.providerDown("vault-http:uninitialized")
        case 503:
            throw SecretsError.providerDown("vault-http:sealed")
        case 307, 472, 473:
            throw SecretsError.providerDown("vault-http:standby")
        default:
            throw SecretsError.providerDown("vault-http:server")
        }
    }

    /// Authenticated KV-v2 read with field selection, lease honor, and
    /// optional wrap-TTL unwrap.
    ///
    /// Whole-item refs (no field) serve the `value` key when present, else
    /// the single key of a one-key secret, else not-found: multi-key
    /// secrets without a field are ambiguous and fail closed. Destroyed or
    /// soft-deleted versions, missing keys, and null values are not-found.
    /// Non-string scalars stringify; objects and arrays re-encode as
    /// sorted-key JSON.
    ///
    /// When `wrapTTL` is set the read carries `X-Vault-Wrap-TTL`; a
    /// `wrap_info.token` answer is unwrapped exactly once (see `unwrap`).
    /// A bare `wrap_info` without token or data fails as
    /// `providerDown("vault-http:wrap")`; data served inline despite a
    /// wrap request is accepted (lenient read). Top-level `lease_id`,
    /// `renewable`, `lease_duration` are tracked when the id is non-empty
    /// and the duration is at least one second; anything else is served
    /// once as a static value.
    func kvRead(path: String, token: String, field: String?, refKey: String) async throws -> SecretValue {
        let url = joining(path)
        var request = authedGet(url: url, token: token)
        if let wrapTTL {
            request.setValue(wrapTTL, forHTTPHeaderField: "X-Vault-Wrap-TTL")
        }
        let (body, response) = try await send(request)
        let status = response.statusCode
        switch status {
        case 200:
            guard let envelope = try? JSONDecoder().decode(VaultKVResponse.self, from: body) else {
                throw SecretsError.providerDown("vault-http:decode")
            }
            if let wrapToken = envelope.wrapInfo?.token, wrapToken.isEmpty == false {
                return try await unwrap(
                    wrappingToken: wrapToken, token: token, field: field, refKey: refKey
                )
            }
            guard let inner = envelope.data else {
                if envelope.wrapInfo != nil {
                    throw SecretsError.providerDown("vault-http:wrap")
                }
                throw SecretsError.providerDown("vault-http:decode")
            }
            let values = try Self.checkLive(inner)
            let value = try Self.selectValue(values: values, field: field)
            await trackLease(envelope: envelope, refKey: refKey, value: value)
            return value
        case 400:
            throw SecretsError.invalidRef("vault-http")
        case 401, 403:
            throw SecretsError.providerDown("vault-http:forbidden")
        case 404:
            throw SecretsError.notFound("vault-http")
        case 429:
            throw SecretsError.providerDown("vault-http:rateLimited")
        case 501:
            throw SecretsError.providerDown("vault-http:uninitialized")
        case 503:
            throw SecretsError.providerDown("vault-http:sealed")
        case 307, 472, 473:
            throw SecretsError.providerDown("vault-http:standby")
        default:
            throw SecretsError.providerDown("vault-http:server")
        }
    }

    /// Unwraps one single-use wrapping token exactly once (T6b
    /// unwrap-after-commit).
    ///
    /// Called only after the wrapped read succeeded (the client-level commit
    /// point). The token is single-use: any failure throws without retry.
    /// Wrap-mechanism failures (rejected token) throw
    /// `providerDown("vault-http:wrap")`; a successful unwrap decodes like
    /// a direct read, including lease honor.
    func unwrap(wrappingToken: String, token: String, field: String?, refKey: String) async throws -> SecretValue {
        let url = joining("/v1/sys/wrapping/unwrap")
        let payload = VaultUnwrapRequest(token: wrappingToken)
        guard let encoded = try? JSONEncoder().encode(payload) else {
            throw SecretsError.providerDown("vault-http:decode")
        }
        let (body, response) = try await send(putJSON(url: url, token: token, body: encoded))
        let status = response.statusCode
        switch status {
        case 200:
            guard let envelope = try? JSONDecoder().decode(VaultKVResponse.self, from: body),
                let inner = envelope.data
            else {
                throw SecretsError.providerDown("vault-http:decode")
            }
            let values = try Self.checkLive(inner)
            let value = try Self.selectValue(values: values, field: field)
            await trackLease(envelope: envelope, refKey: refKey, value: value)
            return value
        case 400, 404:
            throw SecretsError.providerDown("vault-http:wrap")
        case 401, 403:
            throw SecretsError.providerDown("vault-http:forbidden")
        case 429:
            throw SecretsError.providerDown("vault-http:rateLimited")
        case 501:
            throw SecretsError.providerDown("vault-http:uninitialized")
        case 503:
            throw SecretsError.providerDown("vault-http:sealed")
        case 307, 472, 473:
            throw SecretsError.providerDown("vault-http:standby")
        default:
            throw SecretsError.providerDown("vault-http:server")
        }
    }

    /// Live values from one KV inner object: missing data is decode,
    /// destroyed or soft-deleted versions are not-found. Shared by direct
    /// and unwrapped reads.
    private static func checkLive(_ inner: VaultKVInner) throws(SecretsError) -> [String: VaultJSONValue] {
        guard let values = inner.data else {
            throw SecretsError.providerDown("vault-http:decode")
        }
        if inner.metadata?.destroyed == true {
            throw SecretsError.notFound("vault-http")
        }
        if let deletion = inner.metadata?.deletionTime, deletion.isEmpty == false {
            throw SecretsError.notFound("vault-http")
        }
        return values
    }

    /// Selects one value from decoded KV fields: the named field, else the
    /// `value` key, else the single key of a one-key secret. Shared by
    /// direct and unwrapped reads.
    static func selectValue(values: [String: VaultJSONValue], field: String?) throws(SecretsError) -> SecretValue {
        if let field {
            guard let raw = values[field] else {
                throw SecretsError.notFound("vault-http")
            }
            if raw == .null {
                throw SecretsError.notFound("vault-http")
            }
            guard let text = raw.stringified() else {
                throw SecretsError.providerDown("vault-http:decode")
            }
            return .text(text)
        }
        if let direct = values["value"], direct != .null {
            guard let text = direct.stringified() else {
                throw SecretsError.providerDown("vault-http:decode")
            }
            return .text(text)
        }
        guard values.count == 1, let only = values.values.first, only != .null,
            let text = only.stringified()
        else {
            throw SecretsError.notFound("vault-http")
        }
        return .text(text)
    }

    /// Tracks a read lease when usable (non-empty id, duration of at least
    /// one second); static answers are ignored.
    private func trackLease(envelope: VaultKVResponse, refKey: String, value: SecretValue) async {
        guard let leaseID = envelope.leaseID, leaseID.isEmpty == false,
            let duration = envelope.leaseDuration, duration >= 1
        else {
            return
        }
        _ = await tracker.track(
            refKey: refKey, value: value, leaseID: leaseID,
            renewable: envelope.renewable ?? false, leaseDuration: duration
        )
    }
}

// MARK: - Renewal (T6b)

extension VaultHTTPClient {
    /// Renews every due renewable lease, oldest-due first.
    ///
    /// One AppRole login covers the whole cycle when configured; a login
    /// failure fails every due lease with the login cause instead of
    /// throwing. Each lease maps independently: success refreshes its
    /// expiry; definitive rejection (400/404) drops the lease and reports
    /// `.leaseExpired`; transient failures (sealed, forbidden,
    /// uninitialized, rate-limited, standby, server, unreachable, TLS,
    /// timeout, oversized, decode) keep the lease for a later cycle and
    /// report the mapped cause. Only cancellation throws: it aborts the
    /// cycle without recording outcomes for unattempted leases.
    public func renewDueLeases() async throws -> [VaultLeaseRenewal] {
        let due = await tracker.dueLeases()
        guard due.isEmpty == false else { return [] }
        let token: String
        do {
            token = try await loginToken()
        } catch {
            if error is CancellationError {
                throw error
            }
            let cause = (error as? SecretsError) ?? Self.mapTransportError(error)
            return due.map { VaultLeaseRenewal(leaseID: $0.leaseID, outcome: .failed(cause)) }
        }
        var outcomes: [VaultLeaseRenewal] = []
        outcomes.reserveCapacity(due.count)
        for lease in due {
            try Task.checkCancellation()
            outcomes.append(try await renewOne(lease, token: token))
        }
        return outcomes
    }

    /// Renews one lease via `PUT /v1/sys/leases/renew` with
    /// `{lease_id, increment}`. Throws only on cancellation; every Vault
    /// or transport failure becomes an outcome.
    func renewOne(_ lease: VaultLease, token: String) async throws -> VaultLeaseRenewal {
        let url = joining("/v1/sys/leases/renew")
        let payload = VaultRenewRequest(leaseID: lease.leaseID, increment: lease.leaseDuration)
        guard let encoded = try? JSONEncoder().encode(payload) else {
            return VaultLeaseRenewal(leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:decode")))
        }
        let body: Data
        let status: Int
        do {
            let (data, response) = try await send(putJSON(url: url, token: token, body: encoded))
            body = data
            status = response.statusCode
        } catch let error as SecretsError {
            return VaultLeaseRenewal(leaseID: lease.leaseID, outcome: .failed(error))
        } catch {
            if error is CancellationError {
                throw error
            }
            return VaultLeaseRenewal(leaseID: lease.leaseID, outcome: .failed(Self.mapTransportError(error)))
        }
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(VaultRenewResponse.self, from: body),
                let duration = decoded.leaseDuration, duration >= 1
            else {
                return VaultLeaseRenewal(
                    leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:decode"))
                )
            }
            guard let updated = await tracker.didRenew(
                leaseID: lease.leaseID,
                renewable: decoded.renewable ?? false,
                leaseDuration: duration
            ) else {
                // Renewed server-side but no longer tracked (concurrent
                // drop): nothing is held, so report expiry.
                return VaultLeaseRenewal(
                    leaseID: lease.leaseID, outcome: .failed(.leaseExpired("vault-http"))
                )
            }
            return VaultLeaseRenewal(
                leaseID: lease.leaseID,
                outcome: .renewed(expiresAt: updated.expiresAt, leaseDuration: updated.leaseDuration)
            )
        case 400, 404:
            await tracker.drop(leaseID: lease.leaseID)
            return VaultLeaseRenewal(leaseID: lease.leaseID, outcome: .failed(.leaseExpired("vault-http")))
        case 401, 403:
            return VaultLeaseRenewal(
                leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:forbidden"))
            )
        case 429:
            return VaultLeaseRenewal(
                leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:rateLimited"))
            )
        case 501:
            return VaultLeaseRenewal(
                leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:uninitialized"))
            )
        case 503:
            return VaultLeaseRenewal(
                leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:sealed"))
            )
        case 307, 472, 473:
            return VaultLeaseRenewal(
                leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:standby"))
            )
        default:
            return VaultLeaseRenewal(
                leaseID: lease.leaseID, outcome: .failed(.providerDown("vault-http:server"))
            )
        }
    }

    /// Runs renewal cycles until cancelled: one `renewDueLeases` pass per
    /// interval, then sleep. The interval clamps to 0.05 through 3,600
    /// seconds. Returns on cancellation; per-lease failures are outcomes,
    /// never throws, so the loop outlives transient outages.
    public func runRenewalLoop(checkIntervalSeconds: Double = 60) async {
        let interval = min(max(checkIntervalSeconds, 0.05), 3600)
        while true {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            if Task.isCancelled {
                return
            }
            do {
                _ = try await renewDueLeases()
            } catch {
                if error is CancellationError {
                    return
                }
            }
        }
    }
}

// MARK: - Health mapping

extension VaultHTTPClient {
    static func healthOK(status: Int, body: Data) -> Bool {
        do {
            try throwIfHealthDown(status: status, body: body)
            return true
        } catch {
            return false
        }
    }

    static func throwIfHealthDown(status: Int, body: Data) throws(SecretsError) -> Void {
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(VaultHealthResponse.self, from: body) else {
                throw SecretsError.providerDown("vault-http:decode")
            }
            if decoded.initialized == false {
                throw SecretsError.providerDown("vault-http:uninitialized")
            }
            if decoded.sealed == true {
                throw SecretsError.providerDown("vault-http:sealed")
            }
            if decoded.standby == true {
                throw SecretsError.providerDown("vault-http:standby")
            }
            guard let text = decoded.version,
                let version = VaultVersion(parsing: text),
                version >= minimumVersion
            else {
                throw SecretsError.providerDown("vault-http:version")
            }
            return
        case 429:
            if let decoded = try? JSONDecoder().decode(VaultHealthResponse.self, from: body),
                decoded.standby == true
            {
                throw SecretsError.providerDown("vault-http:standby")
            }
            throw SecretsError.providerDown("vault-http:rateLimited")
        case 501:
            throw SecretsError.providerDown("vault-http:uninitialized")
        case 503:
            throw SecretsError.providerDown("vault-http:sealed")
        case 401, 403:
            throw SecretsError.providerDown("vault-http:forbidden")
        case 307, 472, 473:
            throw SecretsError.providerDown("vault-http:standby")
        default:
            throw SecretsError.providerDown("vault-http:server")
        }
    }

    static func mapTransportError(_ error: Error) -> SecretsError {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout("vault-http")
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                .clientCertificateRejected, .clientCertificateRequired,
                .secureConnectionFailed:
                return .providerDown("vault-http:tls")
            default:
                return .providerDown("vault-http:unreachable")
            }
        }
        return .providerDown("vault-http:unreachable")
    }
}

// MARK: - Vault payloads

private struct VaultHealthResponse: Decodable, Sendable {
    var initialized: Bool?
    var sealed: Bool?
    var standby: Bool?
    var version: String?

    private enum CodingKeys: String, CodingKey {
        case initialized
        case sealed
        case standby
        case version
    }
}

private struct VaultLoginRequest: Encodable, Sendable {
    var roleID: String
    var secretID: String

    private enum CodingKeys: String, CodingKey {
        case roleID = "role_id"
        case secretID = "secret_id"
    }
}

private struct VaultLoginResponse: Decodable, Sendable {
    var auth: VaultLoginAuth?

    private enum CodingKeys: String, CodingKey {
        case auth
    }
}

private struct VaultLoginAuth: Decodable, Sendable {
    var clientToken: String
    var accessor: String
    var leaseDuration: Int

    private enum CodingKeys: String, CodingKey {
        case clientToken = "client_token"
        case accessor
        case leaseDuration = "lease_duration"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientToken = (try? container.decode(String.self, forKey: .clientToken)) ?? ""
        accessor = (try? container.decode(String.self, forKey: .accessor)) ?? ""
        leaseDuration = (try? container.decode(Int.self, forKey: .leaseDuration)) ?? 0
    }
}

private struct VaultKVResponse: Decodable, Sendable {
    var data: VaultKVInner?
    var leaseID: String?
    var renewable: Bool?
    var leaseDuration: Int?
    var wrapInfo: VaultWrapInfo?

    private enum CodingKeys: String, CodingKey {
        case data
        case leaseID = "lease_id"
        case renewable
        case leaseDuration = "lease_duration"
        case wrapInfo = "wrap_info"
    }
}

/// Response-wrapping envelope. Only the single-use token is read.
private struct VaultWrapInfo: Decodable, Sendable {
    var token: String?
    var ttl: Int?

    private enum CodingKeys: String, CodingKey {
        case token
        case ttl
    }
}

/// Lease renewal request: `{lease_id, increment}` over PUT.
private struct VaultRenewRequest: Encodable, Sendable {
    var leaseID: String
    var increment: Int

    private enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case increment
    }
}

/// Lease renewal answer: top-level lease fields only.
private struct VaultRenewResponse: Decodable, Sendable {
    var leaseID: String?
    var renewable: Bool?
    var leaseDuration: Int?

    private enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case renewable
        case leaseDuration = "lease_duration"
    }
}

/// Unwrap request: the single-use wrapping token in the body.
private struct VaultUnwrapRequest: Encodable, Sendable {
    var token: String

    private enum CodingKeys: String, CodingKey {
        case token
    }
}

private struct VaultKVInner: Decodable, Sendable {
    var data: [String: VaultJSONValue]?
    var metadata: VaultKVMetadata?

    private enum CodingKeys: String, CodingKey {
        case data
        case metadata
    }
}

private struct VaultKVMetadata: Decodable, Sendable {
    var destroyed: Bool?
    var deletionTime: String?

    private enum CodingKeys: String, CodingKey {
        case destroyed
        case deletionTime = "deletion_time"
    }
}

/// One KV-v2 field value. Strings pass through; scalars stringify;
/// objects and arrays re-encode as sorted-key JSON; null is missing.
enum VaultJSONValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: VaultJSONValue])
    case array([VaultJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode([String: VaultJSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([VaultJSONValue].self) {
            self = .array(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "unsupported JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    func stringified() -> String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self),
                let text = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return text
        case .null:
            return nil
        }
    }
}

/// URLSession delegate that never follows HTTP redirects.
///
/// Vault requests carry the `X-Vault-Token` header or an AppRole body;
/// following a 307/302 would forward that material to the redirect
/// target and let the target's body substitute for Vault's. Refusing
/// surfaces the 3xx status to the standby/server mapping instead.
/// Stateless, so sharing across sessions is safe.
final class VaultNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

#if os(macOS)
/// URLSession delegate enforcing exact leaf DER pinning.
///
/// Immutable after init, so sharing across sessions is safe. Redirects
/// are refused like the system path: a pinned session answers the 3xx
/// itself and never forwards credentials off-origin.
final class VaultPinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let pinned: Data

    init(pinned: Data) {
        self.pinned = pinned
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let leaf = SecTrustGetCertificateAtIndex(trust, 0),
            let der = SecCertificateCopyData(leaf) as Data?,
            der == pinned
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var evaluationError: CFError?
        guard SecTrustEvaluateWithError(trust, &evaluationError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
