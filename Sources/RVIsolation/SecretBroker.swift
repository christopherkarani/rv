import Foundation
import RVDomain
import RVFileStore

// MARK: - File provider

/// Offline file-backed secrets provider (REQ-002).
///
/// Backing decision: values live in a sibling owner-only JSON document,
/// `secrets-file.json`, next to the operator config files
/// (`runtime-resources.json`, `secrets-providers.json`). T3's broker-bound
/// entry types (`RuntimeResourceProfile.BrokerEntry`, `ProviderBinding`)
/// name refs only — provider plus item plus optional field — and never
/// carry secret material, so values need a home with the same owner-only,
/// no-symlink, 64KB discipline as the sibling stores. A separate values
/// file (rather than extending the v1 bindings schema) keeps refs
/// reviewable apart from values and leaves the bindings allowlist
/// untouched.
///
/// Document shape:
/// `{"version":1,"items":{"<item>":{"text":"...","fields":{"<field>":"..."}}}}`.
/// A ref without a field resolves the item's `text`; a ref with a field
/// resolves `fields[field]`. Every failure is typed and provider-only:
/// unknown items or fields are `.notFound("file")`, unreadable or unsafe
/// stores are `.providerDown("file")`. Item names, field names, and values
/// never appear in thrown errors.
///
/// Size caps are staging's job (CON-005): the broker passes values through
/// and T5 drops oversized variables per variable at stage time.
public struct FileSecretsProvider: SecretsProvider, Sendable {
    /// Provider id. Always a member of `SecretRef.allowedProviders`.
    public var id: String { "file" }

    /// Operator config directory holding `secrets-file.json`.
    public var configDirectory: URL

    /// Values file name beside the sibling operator stores.
    public static let fileName = "secrets-file.json"
    /// Largest values document accepted, matching the sibling stores.
    public static let maximumBytes = 65_536
    /// Largest item count accepted.
    public static let maximumItems = 256

    /// Reads values from `fileName` under `configDirectory`.
    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    /// Resolves one file-backed ref. A missing document is an empty store:
    /// every ref then fails closed as `.notFound`, never as provider-down.
    public func resolve(_ ref: SecretRef) async throws -> SecretValue {
        let items: [String: FileSecretRecord]
        switch Self.load(from: configDirectory) {
        case .success(let loaded):
            items = loaded
        case .failure:
            throw SecretsError.providerDown(id)
        }
        guard let record = items[ref.item] else {
            throw SecretsError.notFound(id)
        }
        if let field = ref.field {
            guard let value = record.fields?[field] else {
                throw SecretsError.notFound(id)
            }
            return .text(value)
        }
        guard let value = record.text else {
            throw SecretsError.notFound(id)
        }
        return .text(value)
    }

    /// Reachable when the values document loads (a missing document is an
    /// empty store, still reachable). The file provider authenticates
    /// nothing, so `identity` is always nil.
    public func health() async -> ProviderHealth {
        switch Self.load(from: configDirectory) {
        case .success:
            ProviderHealth(ok: true)
        case .failure:
            ProviderHealth(ok: false)
        }
    }

    private static func load(
        from configDirectory: URL
    ) -> Result<[String: FileSecretRecord], FileSecretsLoadError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data)
        case .failure(.missing):
            return .success([:])
        case .failure(.inaccessible), .failure(.unsafeLocation):
            return .failure(.unsafeLocation)
        case .failure(.unreadable):
            return .failure(.unreadable)
        case .failure(.oversized):
            return .failure(.oversized)
        }
    }

    private static func decode(
        _ data: Data
    ) -> Result<[String: FileSecretRecord], FileSecretsLoadError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(FileSecretsDocument.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        guard document.items.count <= maximumItems else { return .failure(.invalidDocument) }
        for (name, record) in document.items {
            guard SecretLabels.isValidItem(name),
                record.text != nil || record.fields?.isEmpty == false
            else {
                return .failure(.invalidDocument)
            }
            if let fields = record.fields {
                for field in fields.keys where SecretLabels.isValidField(field) == false {
                    return .failure(.invalidDocument)
                }
            }
        }
        return .success(document.items)
    }
}

/// Values-store load failure. Internal: `resolve` and `health` collapse
/// every case to `.providerDown("file")` or unhealthy.
private enum FileSecretsLoadError: Error, Sendable {
    case unsafeLocation
    case unreadable
    case oversized
    case invalidDocument
    case unsupportedVersion
}

/// Temporary alias: tests pin the historical name; new code uses `StrictJSONKey`.
typealias FileSecretsStrictKey = StrictJSONKey

/// Versioned values document: item names to secret records.
private struct FileSecretsDocument: Decodable {
    let version: Int
    let items: [String: FileSecretRecord]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "items"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        items = try container.decode(
            [String: FileSecretRecord].self, forKey: StrictJSONKey("items")
        )
    }
}

/// One item's whole value plus its named sub-values. At least one side
/// must be present; empty strings are explicit empty secrets and allowed.
private struct FileSecretRecord: Decodable {
    let text: String?
    let fields: [String: String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["text", "fields"])
        text = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("text"))
        fields = try container.decodeIfPresent(
            [String: String].self, forKey: StrictJSONKey("fields")
        )
    }
}

// MARK: - Keychain provider

/// macOS keychain-backed secrets provider (REQ-003).
///
/// Ref mapping decision: `ref.item` names the keychain service and
/// `ref.field` names the account (`"default"` when the ref carries no
/// field). The whole secret must decode as UTF-8 text; there is no third
/// level, so unlike `RuntimeResourceProfile.KeychainEntry` this provider
/// performs no JSON-field selection. Missing items, access failures, and
/// non-UTF-8 secrets all fail closed as `.notFound("keychain")` — the
/// caller cannot distinguish them, and the item name never echoes.
///
/// Linux has no keychain (CON-003): `currentPlatform()` returns nil there
/// and a directly constructed instance throws `.providerDown("keychain")`
/// with unhealthy status. The `#if os(macOS)` gate below is the whole
/// platform split; there is no Linux keychain fallback by design.
public struct KeychainSecretsProvider: SecretsProvider, Sendable {
    /// Provider id. Always a member of `SecretRef.allowedProviders`.
    public var id: String { "keychain" }

    /// Host keychain read: service plus account to secret bytes.
    public var read: @Sendable (String, String) -> Data?

    /// Account used when the ref names no field.
    public static let defaultAccount = "default"

    /// Reads through `read`. Production passes `KeychainReader.live`;
    /// tests pass explicit fakes or `KeychainReader.denied`.
    public init(read: @escaping @Sendable (String, String) -> Data?) {
        self.read = read
    }

    /// Reads through a `KeychainReader` sibling.
    init(reader: KeychainReader) {
        self.init(read: reader.read)
    }

    /// Live keychain reads on macOS, nil on Linux (CON-003 fail-closed).
    static func currentPlatform() -> KeychainSecretsProvider? {
        #if os(macOS)
        return KeychainSecretsProvider(reader: .live)
        #else
        return nil
        #endif
    }

    /// Denied reads: every ref fails closed as `.notFound`, on every platform.
    static var denied: KeychainSecretsProvider {
        KeychainSecretsProvider(reader: .denied)
    }

    /// Resolves one keychain-backed ref through the wrapped reader.
    public func resolve(_ ref: SecretRef) async throws -> SecretValue {
        #if os(macOS)
        guard let data = read(ref.item, ref.field ?? Self.defaultAccount),
            let text = String(data: data, encoding: .utf8)
        else {
            throw SecretsError.notFound(id)
        }
        return .text(text)
        #else
        throw SecretsError.providerDown(id)
        #endif
    }

    /// The keychain is always reachable on macOS (per-item failures are
    /// `.notFound`, not provider-down) and never reachable on Linux. The
    /// provider authenticates nothing, so `identity` is always nil.
    public func health() async -> ProviderHealth {
        #if os(macOS)
        return ProviderHealth(ok: true)
        #else
        return ProviderHealth(ok: false)
        #endif
    }
}

// MARK: - Fresh-context liveness

/// Fresh-context check for resolve-then-verify (T0c).
///
/// The broker snapshots at entry and re-checks at commit; a context that
/// dies mid-flight never commits values. The check is two closures so the
/// registry-backed production wiring and scripted test doubles share one
/// seam:
///
/// - `snapshot` captures the entry token (nil when the instance is unknown).
/// - `isLive` re-checks principal liveness plus generation equality, both
///   at entry (against the just-taken snapshot) and at commit.
///
/// `usableOnly` checks the snapshot's own validity only and is never
/// the default: both broker inits require an explicit choice, and T5
/// wires the registry-backed check into the identity gate.
/// `registry(_:)` (same-module; the registry is internal) additionally
/// requires live `.active` validity and an unchanged validity generation,
/// so a revoke between entry and commit fails the commit.
public struct SecretBrokerLiveness: Sendable {
    /// Captures the entry token for one context.
    public var snapshot: @Sendable (AuthenticatedAgentContext) -> UInt64?
    /// Re-checks liveness of one context against its entry token.
    public var isLive: @Sendable (AuthenticatedAgentContext, UInt64?) -> Bool

    /// Assembles a liveness check from its two closures.
    public init(
        snapshot: @escaping @Sendable (AuthenticatedAgentContext) -> UInt64?,
        isLive: @escaping @Sendable (AuthenticatedAgentContext, UInt64?) -> Bool
    ) {
        self.snapshot = snapshot
        self.isLive = isLive
    }

    /// Snapshot-validity check only. Trusts the context's cached
    /// validity and never consults the registry, so a revoked instance
    /// keeps resolving until its cached context lapses. Tests and
    /// single-use scripts only; production wiring passes `registry(_:)`.
    public static let usableOnly = SecretBrokerLiveness(
        snapshot: { $0.isUsable ? 0 : nil },
        isLive: { ctx, token in token == 0 && ctx.isUsable }
    )

    /// Registry-backed liveness: live `.active` validity plus an unchanged
    /// generation between the entry snapshot and the commit check.
    static func registry(_ registry: AgentInstanceRegistry) -> SecretBrokerLiveness {
        SecretBrokerLiveness(
            snapshot: { registry.generation(of: $0.instance.id) },
            isLive: { ctx, token in
                guard ctx.isUsable,
                    let token,
                    registry.validity(of: ctx.instance.id) == .active,
                    registry.generation(of: ctx.instance.id) == token
                else {
                    return false
                }
                return true
            }
        )
    }
}

// MARK: - Audit sink

/// Audit append seam. The broker awaits one append per `resolve` call
/// before committing (audit-before-commit, T0c): resolved rows on success,
/// denied rows on every failure. Rows are `SecretsAuditRecord` built by the
/// `secretResolve` factory, so the file-backed production wiring appends to
/// `<directory>/secrets-audit.jsonl` through the shared ledger writer with
/// no conversion step; tests inject a temp directory or a capturing closure.
public struct SecretBrokerAuditSink: Sendable {
    /// Appends one call's rows. An empty batch appends nothing.
    public var append: @Sendable ([SecretsAuditRecord]) async throws -> Void

    /// Appends through `append`.
    public init(append: @escaping @Sendable ([SecretsAuditRecord]) async throws -> Void) {
        self.append = append
    }

    /// File-backed sink rooted at `directory`, sharing the ledger writer
    /// (and its byte budget) with every other audit path. Ledger failures
    /// surface directly as `SecretsLedgerError`. Tests pass an isolated
    /// temp directory here.
    public static func file(
        directory: URL,
        retention: SecretsAuditRetention = .default
    ) -> SecretBrokerAuditSink {
        SecretBrokerAuditSink(append: { records in
            try SecretsLedger.append(records, directory: directory, retention: retention)
        })
    }
}

// MARK: - Broker

/// Mediated secret resolution over registered providers (REQ-005).
///
/// The broker holds `[id: any SecretsProvider]` and resolves batches only
/// for a fresh `AuthenticatedAgentContext`, following the T0c
/// pre-decisions:
///
/// - Resolve-then-verify: the entry check requires a usable context plus a
///   live liveness snapshot; the commit check re-verifies liveness against
///   the entry token. A context revoked mid-flight throws
///   `.identityRequired` and commits nothing.
/// - Atomic broker: batch resolution is all-or-nothing. The first failure
///   aborts the batch; no partial map is ever returned.
/// - Per-RPC timeout: every provider `health()` and `resolve(_:)` runs
///   under `timeoutSeconds`; expiry throws `.timeout(provider)`. The
///   budget needs cooperative cancellation: a provider that ignores
///   cancellation delays the batch but its late value is always discarded,
///   never committed.
/// - Audit-before-commit: one audit append per call lands before values
///   return. Denied rows precede every throw; resolved rows precede every
///   return. A failed commit append denies the batch as `.denied("audit")`,
///   while task cancellation during the append propagates as
///   `CancellationError` like every other phase.
///
/// Errors are typed `SecretsError` and provider-only: unknown providers,
/// unhealthy providers, timeouts, stale contexts, and foreign provider
/// errors all map to cases naming the provider id (or nothing), never the
/// item, field, or value. Task cancellation propagates as
/// `CancellationError` without committing values and without audit.
public actor SecretBroker {
    private let providers: [String: any SecretsProvider]
    private let audit: SecretBrokerAuditSink
    private let liveness: SecretBrokerLiveness
    private let timeoutSeconds: Double
    private let now: @Sendable () -> Date

    /// Holds `providers` (later registrations win on duplicate ids),
    /// auditing through `audit`, verifying through `liveness`, and timing
    /// each provider RPC with `timeoutSeconds`.
    public init(
        providers: [any SecretsProvider],
        audit: SecretBrokerAuditSink,
        liveness: SecretBrokerLiveness,
        timeoutSeconds: Double = 5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        self.audit = audit
        self.liveness = liveness
        self.timeoutSeconds = timeoutSeconds
        self.now = now
    }

    /// Holds `providers`, auditing to `<auditDirectory>/secrets-audit.jsonl`.
    /// Tests pass an isolated temp directory here.
    public init(
        providers: [any SecretsProvider],
        auditDirectory: URL,
        liveness: SecretBrokerLiveness,
        timeoutSeconds: Double = 5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            providers: providers,
            audit: .file(directory: auditDirectory),
            liveness: liveness,
            timeoutSeconds: timeoutSeconds,
            now: now
        )
    }

    /// Registered provider ids, sorted.
    public var providerIDs: [String] {
        providers.keys.sorted()
    }

    /// Resolves one atomic batch for a fresh context.
    ///
    /// Ordering: principal gate, liveness snapshot plus entry check,
    /// provider registration precheck, per-provider health gating, timed
    /// resolution into a scratch map, commit liveness check, audit append,
    /// then return. Empty batches return `[:]` after the gate and audit
    /// nothing. Every failure path appends denied rows (best-effort: a
    /// failed failure-path append keeps the original error) and throws the
    /// typed, provider-only cause.
    public func resolve(
        _ refs: [SecretRef],
        ctx: AuthenticatedAgentContext
    ) async throws -> [SecretRef: SecretValue] {
        let call = BrokerCall(
            refs: Self.unique(refs),
            executionID: SecretsExecutionID(),
            correlationID: SecretsCorrelationID(),
            principal: SecretsAuditPrincipal(context: ctx),
            timestamp: now()
        )
        guard ctx.isUsable else {
            try await deny(.identityRequired, call: call)
        }
        let token = liveness.snapshot(ctx)
        guard liveness.isLive(ctx, token) else {
            try await deny(.identityRequired, call: call)
        }
        guard call.refs.isEmpty == false else {
            return [:]
        }
        for ref in call.refs where providers[ref.provider] == nil {
            try await deny(.providerDown(ref.provider), call: call)
        }
        for id in Self.involved(call.refs) {
            guard let provider = providers[id] else {
                try await deny(.providerDown(id), call: call)
            }
            let health: ProviderHealth
            do {
                health = try await rpc(provider: id) { await provider.health() }
            } catch let error as SecretsError {
                try await deny(Self.thrownBy(error, provider: id), call: call)
            } catch {
                if error is CancellationError {
                    throw error
                }
                try await deny(.providerDown(id), call: call)
            }
            guard health.ok else {
                try await deny(.providerDown(id), call: call)
            }
        }
        var values: [SecretRef: SecretValue] = [:]
        values.reserveCapacity(call.refs.count)
        for ref in call.refs {
            guard let provider = providers[ref.provider] else {
                try await deny(.providerDown(ref.provider), call: call)
            }
            do {
                values[ref] = try await rpc(provider: ref.provider) {
                    try await provider.resolve(ref)
                }
            } catch let error as SecretsError {
                try await deny(Self.thrownBy(error, provider: ref.provider), call: call)
            } catch {
                if error is CancellationError {
                    throw error
                }
                try await deny(.providerDown(ref.provider), call: call)
            }
        }
        guard liveness.isLive(ctx, token) else {
            try await deny(.identityRequired, call: call)
        }
        do {
            try await audit.append(call.resolved())
        } catch {
            if error is CancellationError {
                throw error
            }
            throw SecretsError.denied("audit")
        }
        return values
    }

    /// Appends denied rows for the whole batch, then throws. The append is
    /// best-effort: the batch is already denied, so a failed append keeps
    /// the original error instead of masking it.
    private func deny(_ error: SecretsError, call: BrokerCall) async throws -> Never {
        try? await audit.append(call.denied(error))
        throw error
    }

    /// Re-tags a provider-thrown error to the provider that threw it. A
    /// compromised or buggy provider must not misattribute its failures —
    /// or their audit causes — to another provider. Errors without a
    /// provider payload pass through: they name no provider to spoof.
    private static func thrownBy(_ error: SecretsError, provider: String) -> SecretsError {
        switch error {
        case .invalidRef:
            .invalidRef(provider)
        case .notFound:
            .notFound(provider)
        case .denied:
            .denied(provider)
        case .identityRequired:
            .identityRequired
        case .leaseExpired:
            .leaseExpired(provider)
        case .providerDown:
            .providerDown(provider)
        case .oversized:
            .oversized(provider)
        case .policyDenied:
            .policyDenied
        case .timeout:
            .timeout(provider)
        }
    }

    /// Runs one provider RPC under the per-RPC budget. A nonpositive
    /// budget denies immediately without touching the provider.
    private func rpc<T: Sendable>(
        provider: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard timeoutSeconds > 0 else {
            throw SecretsError.timeout(provider)
        }
        let budget = timeoutSeconds
        let outcome: Result<T, Error> = await withTaskGroup(
            of: Result<T, Error>.self,
            returning: Result<T, Error>.self
        ) { group in
            group.addTask {
                do {
                    return .success(try await operation())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(budget))
                    return .failure(SecretsError.timeout(provider))
                } catch {
                    return .failure(error)
                }
            }
            guard let first = await group.next() else {
                return .failure(SecretsError.timeout(provider))
            }
            group.cancelAll()
            return first
        }
        // A provider that swallows cancellation must not commit values for
        // a cancelled call: cancellation wins over a raced success.
        try Task.checkCancellation()
        // A provider that throws CancellationError without cancellation is
        // faulty or hostile: deny as provider-down so the batch is audited
        // instead of escaping the ledger with zero rows. The check above
        // already threw for genuine cancellation, so the explicit flag read
        // only guards against reordering, not a suspension (there is none
        // between the check and the read).
        if case .failure(let error) = outcome, error is CancellationError, !Task.isCancelled {
            throw SecretsError.providerDown(provider)
        }
        return try outcome.get()
    }

    /// Order-preserving dedupe: one row and one resolution per unique ref.
    private static func unique(_ refs: [SecretRef]) -> [SecretRef] {
        var seen = Set<SecretRef>()
        return refs.filter { seen.insert($0).inserted }
    }

    /// Sorted provider ids named by one batch. Health gating follows this
    /// order, so multi-provider failures are deterministic.
    private static func involved(_ refs: [SecretRef]) -> [String] {
        Array(Set(refs.map(\.provider))).sorted()
    }
}

/// One broker call's audit context. Pure row builders: the broker decides,
/// this formats.
private struct BrokerCall: Sendable {
    var refs: [SecretRef]
    var executionID: SecretsExecutionID
    var correlationID: SecretsCorrelationID
    var principal: SecretsAuditPrincipal
    var timestamp: Date

    /// One resolved row per ref. Causes stay nil: success needs no cause.
    func resolved() -> [SecretsAuditRecord] {
        refs.map {
            SecretsAuditRecord.secretResolve(
                executionID: executionID,
                timestamp: timestamp,
                principal: principal,
                ref: $0,
                decision: .resolved,
                correlationID: correlationID
            )
        }
    }

    /// One denied row per ref sharing the batch's provider-only cause.
    /// Atomic batches fail together, so every ref carries the denial.
    func denied(_ error: SecretsError) -> [SecretsAuditRecord] {
        let cause = SecretsAuditCause(error)
        return refs.map {
            SecretsAuditRecord.secretResolve(
                executionID: executionID,
                timestamp: timestamp,
                principal: principal,
                ref: $0,
                decision: .denied,
                correlationID: correlationID,
                cause: cause
            )
        }
    }
}
