import Foundation
import RVDomain

// MARK: - Auth

/// How one 1Password account authenticates its `op` spawns.
///
/// Ports the executor's `ResolvedAuth` union
/// (`packages/plugins/onepassword/src/sdk/service.ts`): desktop-app auth
/// addresses one signed-in account through `--account`, while the
/// service-account token travels in the child's environment only, never in
/// argv. The token is secret material: it never appears in errors, and the
/// redacted projection below strips it structurally.
public enum OnePasswordAuth: Sendable, Equatable {
    /// Biometric-backed desktop-app account (`--account=<name>`).
    case desktopApp(accountName: String)
    /// Headless service-account token (`OP_SERVICE_ACCOUNT_TOKEN` in env).
    case serviceAccount(token: String)
}

// MARK: - Redacted descriptions

/// Token material never prints: the service-account token redacts in both
/// `description` and `debugDescription`, so crash reports, debug logs, and
/// test-failure output cannot carry it. The desktop-app account name
/// survives (it addresses, never authenticates), matching the redacted
/// projection below.
extension OnePasswordAuth: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .desktopApp(let accountName):
            return "desktopApp(accountName: \"\(accountName)\")"
        case .serviceAccount:
            return "serviceAccount(<redacted>)"
        }
    }

    public var debugDescription: String {
        description
    }
}

/// Account description through the redacted projection: ids, names,
/// vaults, and the auth shape print; token material cannot.
extension OnePasswordAccount: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let redacted: OnePasswordRedactedAuth
        switch auth {
        case .desktopApp(let accountName):
            redacted = .desktopApp(accountName: accountName)
        case .serviceAccount:
            redacted = .serviceAccount
        }
        return "OnePasswordAccount(id: \"\(id)\", name: \"\(name)\", auth: \(redacted), "
            + "vaults: \(vaults))"
    }

    public var debugDescription: String {
        description
    }
}

/// Provider description carries the redacted accounts only: routing stays
/// debuggable while token material cannot print.
extension OnePasswordSecretsProvider: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OnePasswordSecretsProvider(id: \"\(id)\", accounts: \(redactedAccounts), "
            + "opCommand: \"\(opCommand)\")"
    }

    public var debugDescription: String {
        description
    }
}

/// One vault an account scopes operations to.
///
/// Ports the executor's `Vault` row (`sdk/types.ts`): the id is globally
/// unique, the name only per account, which is why a name configured in two
/// accounts is an ambiguity failure, never a precedence pick.
public struct OnePasswordVault: Sendable, Equatable, Hashable {
    /// Globally unique vault id.
    public let id: String
    /// Display name, unique per account at most.
    public let name: String

    /// Assembles one scoped vault.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One named auth binding plus the vaults it scopes to.
///
/// Ports the executor's `OnePasswordAccount` (`sdk/types.ts`): an owner can
/// hold several accounts (work next to personal, or a service-account token
/// next to desktop-app biometrics). Refs never embed the account id —
/// `op://` addressing stays vault-first — so re-authing an account never
/// invalidates a stored ref.
public struct OnePasswordAccount: Sendable, Equatable {
    /// Stable account id. Never embedded in refs.
    public let id: String
    /// Human label, used only to disambiguate matches.
    public let name: String
    /// How this account's `op` spawns authenticate.
    public let auth: OnePasswordAuth
    /// Vaults this account scopes operations to.
    public let vaults: [OnePasswordVault]

    /// Assembles one account binding.
    public init(id: String, name: String, auth: OnePasswordAuth, vaults: [OnePasswordVault]) {
        self.id = id
        self.name = name
        self.auth = auth
        self.vaults = vaults
    }
}

// MARK: - Redacted projection

/// Auth shape safe for external exposure.
///
/// Ports the executor's `RedactedOnePasswordAuth` (`sdk/types.ts`): the
/// desktop account name survives (it addresses, not authenticates) while the
/// service-account token is dropped — there is no payload to leak.
public enum OnePasswordRedactedAuth: Sendable, Equatable {
    /// Desktop-app account name, kept.
    case desktopApp(accountName: String)
    /// Service-account kind only; the token is stripped.
    case serviceAccount
}

/// Account shape safe for external exposure: auth redacted, vaults kept.
///
/// Ports the executor's `RedactedOnePasswordConfig` row: `getConfig redacts
/// every account's service-account token` (`sdk/plugin.test.ts`) holds here
/// by construction — no redacted value carries token material.
public struct OnePasswordRedactedAccount: Sendable, Equatable {
    /// Stable account id.
    public let id: String
    /// Human label.
    public let name: String
    /// Redacted auth: never token material.
    public let auth: OnePasswordRedactedAuth
    /// Scoped vaults, unchanged.
    public let vaults: [OnePasswordVault]
}

// MARK: - Provider

/// 1Password secrets provider over the `op` CLI (X1-F).
///
/// CLI-only by ticket decision: unlike the executor's dual native-SDK/op-CLI
/// service (`sdk/service.ts`), there is deliberately no SDK fallback — a
/// missing CLI fails closed as `.providerDown("onepassword:cli")` instead of
/// `falls back to the SDK when the CLI is not installed` (`sdk/service.test.ts`,
/// unported). Every ref needs only `op`; every spawn is async with a timeout
/// kill, never blocking a thread (the executor's `sdk/op-cli.ts` rationale).
///
/// Ref addressing ports `resolveConfiguredRef` (`sdk/plugin.test.ts`):
/// `op://vault/item/field...` resolves as-is via the account that owns the
/// vault; `op://vault/item` gains the `credential` field; vaults address by
/// id (first owning account serves) or by name (two owners is an ambiguity
/// failure); a bare item id or title must match exactly one item across every
/// account's vaults. `SecretRef.field`, when present, selects the read field
/// instead of `credential`, mirroring the file provider's field rule.
///
/// Thrown errors are typed `SecretsError` and labels-only per the RV
/// contract, so the executor's human-readable ambiguity and troubleshooting
/// messages collapse onto cases: ambiguity (either shape) is
/// `.denied("onepassword:ambiguous")`; backend RPC failures (a non-zero
/// exit, undecodable output) are `.providerDown("onepassword")` —
/// `notFound` means authoritative absence only (no match, unknown
/// vault, malformed URI), matching the WorkOS Vault provider;
/// killed-by-timeout spawns are `.timeout("onepassword")`; oversized CLI
/// output is `.oversized("onepassword")`; a missing `op` is
/// `.providerDown("onepassword:cli")`; zero accounts is
/// `.providerDown("onepassword")` (the `status reports not-configured before
/// configure` shape). Task cancellation propagates as `CancellationError`.
///
/// Successful top-level resolutions are cached for `cacheTTLSeconds`
/// (porting the executor's `makeCachedRefResolver`): repeats within the TTL
/// serve from memory without spawning; failures, ambiguity, and not-found
/// are never retained; any account change (including token rotation) drops
/// the cached generation at the next lookup. Health probes always reach
/// the backend.
public struct OnePasswordSecretsProvider: SecretsProvider, Sendable {
    /// Provider id. Admitted by `SecretRef.allowedProviders`.
    public var id: String { "onepassword" }

    /// Configured accounts, in routing order.
    public var accounts: [OnePasswordAccount]
    /// `op` command: an absolute path used directly, or a bare name resolved
    /// through the pinned spawn `PATH` only — never the daemon's ambient
    /// `PATH`, so a hijacked daemon entry cannot reroute the spawn.
    public var opCommand: String
    /// Per-spawn timeout in seconds. Non-positive budgets time out without
    /// spawning.
    public var timeoutSeconds: Double
    /// How long a resolved secret may be served from memory before the
    /// backend is asked again. Non-positive disables reuse: every
    /// sequential resolution reaches the backend. Only successful
    /// resolutions are retained; failures, ambiguity, and not-found never
    /// stick, and any config change drops the whole generation.
    public var cacheTTLSeconds: Double
    /// Base environment for spawns. Production reads the live process
    /// environment; tests pass fixed maps. The child never inherits this
    /// map: `spawnEnvironment` rebuilds from an allowlist, so daemon
    /// secrets (notably `EXECUTOR_SECRET_KEY`) never reach `op`.
    public var environment: @Sendable () -> [String: String]

    /// Shared resolution cache. A reference, so every copy of this provider
    /// value serves one generation; the generation fingerprint is the
    /// account list itself, so a rotated token or edited vault set drops
    /// stale entries even across copies.
    private let refCache = OnePasswordRefCache()

    /// Default `op` command, resolved through `PATH`.
    public static let defaultOPCommand = "op"
    /// Default per-spawn timeout, porting the executor's 15s default.
    public static let defaultTimeoutSeconds = 15.0
    /// Default secret-cache TTL, porting the executor's 60s default.
    public static let defaultCacheTTLSeconds = 60.0
    /// Largest cached-secret count, porting the executor's 256-entry cap.
    static let secretCacheCapacity = 256
    /// Field appended to picker-shaped `op://vault/item` refs.
    public static let credentialField = "credential"
    /// Child-only service-account token variable.
    static let serviceAccountTokenVariable = "OP_SERVICE_ACCOUNT_TOKEN"
    /// Largest single spawn output accepted (1 MiB, mirroring Vault).
    static let maximumOutputBytes = 1_048_576

    /// Assembles a provider over `accounts`.
    public init(
        accounts: [OnePasswordAccount],
        opCommand: String = defaultOPCommand,
        timeoutSeconds: Double = defaultTimeoutSeconds,
        cacheTTLSeconds: Double = defaultCacheTTLSeconds,
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.accounts = accounts
        self.opCommand = opCommand
        self.timeoutSeconds = timeoutSeconds
        self.cacheTTLSeconds = cacheTTLSeconds
        self.environment = environment
    }

    /// Redacted accounts for external exposure. Service-account tokens never
    /// survive this projection.
    public var redactedAccounts: [OnePasswordRedactedAccount] {
        accounts.map { account in
            OnePasswordRedactedAccount(
                id: account.id, name: account.name,
                auth: Self.redactedAuth(account.auth), vaults: account.vaults
            )
        }
    }

    /// Strips token material from one auth binding.
    private static func redactedAuth(_ auth: OnePasswordAuth) -> OnePasswordRedactedAuth {
        switch auth {
        case .desktopApp(let accountName):
            return .desktopApp(accountName: accountName)
        case .serviceAccount:
            return .serviceAccount
        }
    }

    /// Resolves one 1Password-backed ref. Ordering: cancellation, provider
    /// check, configured check, cache lookup, then vault-qualified or bare
    /// resolution. Only successful resolutions are stored; every throw
    /// propagates without touching the cache, so failures, ambiguity, and
    /// not-found are never retained. Cancellation is checked before the
    /// lookup, so a cancelled task is never served from memory either.
    public func resolve(_ ref: SecretRef) async throws -> SecretValue {
        try Task.checkCancellation()
        guard ref.provider == id else {
            throw SecretsError.invalidRef(id)
        }
        guard accounts.isEmpty == false else {
            throw SecretsError.providerDown(id)
        }
        let key = OnePasswordCacheKey(item: ref.item, field: ref.field)
        if let hit = await refCache.lookup(key: key, accounts: accounts) {
            return hit
        }
        let value: SecretValue
        if ref.item.hasPrefix("op://") {
            value = try await resolveQualified(item: ref.item, field: ref.field)
        } else {
            value = try await resolveBare(item: ref.item, field: ref.field)
        }
        await refCache.store(
            key: key, value: value,
            accounts: accounts, ttlSeconds: cacheTTLSeconds
        )
        return value
    }

    /// Reachable only when configured and every account answers `vault list`
    /// with decodable JSON, porting `ConnectionStatus.connected` (`sdk/types.ts`:
    /// "True only when configured and every account is reachable"). Never
    /// throws: every failure (including cancellation) reports unhealthy.
    /// Identity is always nil: 1Password sessions are per-spawn, and health
    /// proves reachability, not identity. A configured vault missing from the
    /// live listing does not fail health — the executor stays connected with
    /// an error note there, and `ProviderHealth` has no note channel — so
    /// refs into it fail at read time instead.
    public func health() async -> ProviderHealth {
        guard accounts.isEmpty == false else {
            return ProviderHealth(ok: false)
        }
        for account in accounts {
            let outcome = await spawn(
                arguments: ["vault", "list", "--format=json"], account: account
            )
            guard outcome.ok,
                (try? JSONDecoder().decode(
                    [OnePasswordVaultRow].self, from: outcome.stdout
                )) != nil
            else {
                return ProviderHealth(ok: false)
            }
        }
        return ProviderHealth(ok: true)
    }

    /// Resolves a vault-qualified `op://` ref through its owning account. A
    /// present `field` extends the URI, so `op://vault/item` plus field
    /// `password` reads `op://vault/item/password` as-is.
    internal func resolveQualified(item: String, field: String?) async throws -> SecretValue {
        let uri = item + (field.map { "/\($0)" } ?? "")
        let segments = uri.dropFirst("op://".count).split(
            separator: "/", omittingEmptySubsequences: false
        ).map(String.init)
        guard segments.count >= 2, segments.allSatisfy({ $0.isEmpty == false }) else {
            throw SecretsError.notFound(id)
        }
        let vaultSegment = segments[0]
        let readURI = segments.count == 2 ? uri + "/\(Self.credentialField)" : uri
        if let owner = accounts.first(where: {
            $0.vaults.contains(where: { $0.id == vaultSegment })
        }) {
            return try await read(uri: readURI, account: owner)
        }
        // Pairs, not accounts: the executor flatMaps (account, vault), so
        // one account configuring the same vault name twice is ambiguity
        // too — passing the name through would let `op` pick opaquely.
        let nameOwners: [OnePasswordAccount] = accounts.flatMap { account in
            account.vaults.filter { $0.name == vaultSegment }.map { _ in account }
        }
        guard nameOwners.count < 2 else {
            throw SecretsError.denied("\(id):ambiguous")
        }
        guard let owner = nameOwners.first else {
            throw SecretsError.notFound(id)
        }
        return try await read(uri: readURI, account: owner)
    }

    /// Resolves a bare item id or title: exactly one match across every
    /// account's vaults reads `op://vaultId/itemId/<field ?? credential>`;
    /// zero matches is not-found, several is ambiguity. Any listing backend
    /// failure is provider-down — only a clean empty listing proves
    /// absence — except timeouts, oversized output, and a missing CLI,
    /// which keep their types.
    internal func resolveBare(item: String, field: String?) async throws -> SecretValue {
        var matches: [OnePasswordMatch] = []
        for account in accounts {
            for vault in account.vaults {
                try Task.checkCancellation()
                let rows = try await listItems(vaultID: vault.id, account: account)
                for row in rows where row.id == item || row.title == item {
                    matches.append(
                        OnePasswordMatch(account: account, vault: vault, itemID: row.id)
                    )
                }
            }
        }
        guard matches.count < 2 else {
            throw SecretsError.denied("\(id):ambiguous")
        }
        guard let only = matches.first else {
            throw SecretsError.notFound(id)
        }
        let selector = field ?? Self.credentialField
        return try await read(
            uri: "op://\(only.vault.id)/\(only.itemID)/\(selector)", account: only.account
        )
    }

    /// Reads one `op://` URI. `op read` appends a trailing newline, stripped
    /// the same way (`[\r\n]+$`), so stored secrets stay unchanged. An empty
    /// read is an explicit empty secret, mirroring the file provider.
    private func read(uri: String, account: OnePasswordAccount) async throws -> SecretValue {
        try Task.checkCancellation()
        let outcome = await spawn(arguments: ["read", uri], account: account)
        try Task.checkCancellation()
        guard outcome.ok else {
            throw mapFailure(outcome)
        }
        guard let text = String(data: outcome.stdout, encoding: .utf8) else {
            throw SecretsError.providerDown(id)
        }
        return .text(text.replacingOccurrences(
            of: #"[\r\n]+$"#, with: "", options: .regularExpression
        ))
    }

    /// Lists one vault's items through the CLI's JSON output. Unknown row
    /// members are ignored; undecodable output is provider-down (the
    /// backend answered, but not with a listing).
    private func listItems(vaultID: String, account: OnePasswordAccount) async throws -> [OnePasswordItemRow] {
        let outcome = await spawn(
            arguments: ["item", "list", "--vault", vaultID, "--format=json"], account: account
        )
        try Task.checkCancellation()
        guard outcome.ok else {
            throw mapFailure(outcome)
        }
        guard let rows = try? JSONDecoder().decode(
            [OnePasswordItemRow].self, from: outcome.stdout
        ) else {
            throw SecretsError.providerDown(id)
        }
        return rows
    }

    /// Spawns `op` once under `account`'s auth. Desktop-app spawns serialize
    /// through the prompt gate and carry `--account` last; service-account
    /// spawns run unrestricted with the token in the child environment only.
    private func spawn(arguments: [String], account: OnePasswordAccount) async -> OnePasswordSpawnOutcome {
        let args: [String]
        switch account.auth {
        case .desktopApp(let accountName):
            args = arguments + ["--account=\(accountName)"]
        case .serviceAccount:
            args = arguments
        }
        let env = Self.spawnEnvironment(base: environment(), auth: account.auth)
        if case .desktopApp = account.auth {
            do {
                return try await OnePasswordDesktopSpawnGate.shared.run {
                    await OnePasswordCLIRunner.exec(
                        command: opCommand, arguments: args,
                        environment: env, timeoutSeconds: timeoutSeconds
                    )
                }
            } catch {
                return OnePasswordSpawnOutcome.cancelled
            }
        }
        return await OnePasswordCLIRunner.exec(
            command: opCommand, arguments: args,
            environment: env, timeoutSeconds: timeoutSeconds
        )
    }

    /// Child `PATH`: pinned search dirs for a bare `opCommand`, never the
    /// daemon's. Mirrors N's `minimalEnvironment` precedent.
    static let spawnPathValue = "/usr/bin:/bin"

    /// Per-spawn environment, rebuilt from an allowlist: the pinned `PATH`
    /// and `LANG`/`LC_ALL` (deterministic CLI diagnostics), the inherited
    /// `HOME`/`TMPDIR` and `XDG_*` entries desktop-app auth needs, plus the
    /// per-account token for service-account auth only. Everything else —
    /// notably an inherited token (which would override `--account` and
    /// silently reroute a desktop-app call) and every other daemon secret
    /// such as `EXECUTOR_SECRET_KEY` — never reaches the child.
    static func spawnEnvironment(
        base: [String: String], auth: OnePasswordAuth
    ) -> [String: String] {
        var env: [String: String] = [
            "PATH": spawnPathValue,
            "LANG": "C",
            "LC_ALL": "C",
        ]
        for key in ["HOME", "TMPDIR"] {
            if let value = base[key] {
                env[key] = value
            }
        }
        for (key, value) in base where key.hasPrefix("XDG_") {
            env[key] = value
        }
        if case .serviceAccount(let token) = auth {
            env[serviceAccountTokenVariable] = token
        }
        return env
    }

    /// Maps a failed spawn onto its typed cause. Only CLI-missing, timeout,
    /// and oversized keep their types; every other backend failure is
    /// provider-down — a non-zero exit masks auth, backend, and
    /// missing-item failures alike, so it can never prove absence.
    /// Labels name the provider and cause only.
    private func mapFailure(_ outcome: OnePasswordSpawnOutcome) -> SecretsError {
        if outcome.cliMissing {
            return SecretsError.providerDown("\(id):cli")
        }
        if outcome.timedOut {
            return SecretsError.timeout(id)
        }
        if outcome.oversized {
            return SecretsError.oversized(id)
        }
        return SecretsError.providerDown(id)
    }
}

/// One bare-ref match: the item plus the account and vault that serve it.
struct OnePasswordMatch: Sendable {
    /// Account whose auth serves the read.
    let account: OnePasswordAccount
    /// Vault holding the item.
    let vault: OnePasswordVault
    /// Item id for the read URI.
    let itemID: String
}

/// One `vault list --format=json` row. Unknown members are ignored.
struct OnePasswordVaultRow: Decodable, Sendable {
    /// Vault id.
    let id: String
    /// Vault name.
    let name: String
}

/// One `item list --format=json` row. Unknown members are ignored.
struct OnePasswordItemRow: Decodable, Sendable {
    /// Item id.
    let id: String
    /// Item title.
    let title: String
}

// MARK: - Cached ref resolver

/// Key for one cached resolution: the ref's item plus its field selector.
///
/// A struct, not a joined string, so an item containing the separator can
/// never collide with a (shorter item, field) pair.
struct OnePasswordCacheKey: Hashable, Sendable {
    /// Ref item: an `op://` URI or a bare item id/title.
    let item: String
    /// Field selector, when the ref carries one.
    let field: String?
}

/// One cached successful resolution.
private struct OnePasswordCacheEntry: Sendable {
    /// Resolved secret, served until `expiresAt`.
    let value: SecretValue
    /// Lookup time at which the entry stops serving.
    let expiresAt: Date
}

/// TTL cache over resolved secrets.
///
/// Ports the executor's `makeCachedRefResolver` (`sdk/plugin.ts`): every
/// 1Password read costs at least one `op` spawn (~1s under desktop-app
/// auth; a bare ref pays a per-vault listing on top), so successful
/// resolutions are served from memory for a short TTL. Single generation:
/// the fingerprint is the account list itself (auth material included, so
/// a rotated token is a new generation), and any change drops every cached
/// secret immediately — a removed account's secrets never outlive the
/// config that granted them. Only successes are stored; not-found,
/// ambiguity, and backend failures are never retained, so a just-created
/// item resolves on the next call. Entries past the 256-entry cap evict
/// oldest-inserted first. Lookup and store are serialized through the
/// actor; concurrent same-ref misses each read the backend (last store
/// wins), which stays correct because the backend is the authority.
actor OnePasswordRefCache {
    /// Accounts the cached generation was resolved under. Nil until the
    /// first lookup or store establishes it.
    private var generation: [OnePasswordAccount]?
    /// Live entries by ref key.
    private var entries: [OnePasswordCacheKey: OnePasswordCacheEntry] = [:]
    /// Insertion order for oldest-first eviction.
    private var order: [OnePasswordCacheKey] = []

    /// Serves a live entry, or nil on generation change, miss, or expiry.
    /// A changed `accounts` drops the whole cached generation first.
    func lookup(key: OnePasswordCacheKey, accounts: [OnePasswordAccount]) -> SecretValue? {
        if generation != accounts {
            generation = accounts
            entries = [:]
            order = []
            return nil
        }
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > Date() else {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        return entry.value
    }

    /// Stores one successful resolution. A non-positive TTL stores
    /// nothing, so every sequential resolution reaches the backend. A
    /// store under a stale generation (accounts changed mid-flight) is
    /// dropped rather than kept.
    func store(
        key: OnePasswordCacheKey, value: SecretValue,
        accounts: [OnePasswordAccount], ttlSeconds: Double
    ) {
        guard ttlSeconds > 0 else { return }
        guard generation == accounts else { return }
        entries[key] = OnePasswordCacheEntry(
            value: value, expiresAt: Date().addingTimeInterval(ttlSeconds)
        )
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > OnePasswordSecretsProvider.secretCacheCapacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }
}

// MARK: - Desktop spawn gate

/// Serializes desktop-app `op` spawns.
///
/// Ports the executor's `cliPromptLock` (`sdk/service.ts`): the 1Password
/// desktop app shows at most one CLI-authorization prompt at a time, so
/// desktop-app spawns queue here instead of stacking invisible prompts behind
/// each other. Service-account spawns never prompt and bypass the gate.
actor OnePasswordDesktopSpawnGate {
    /// Process-wide gate, mirroring the executor's module-level lock.
    static let shared = OnePasswordDesktopSpawnGate()

    /// Held permits (0 or 1).
    private var holders = 0
    /// FIFO waiters for the permit.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` holding the gate's single permit. Cancellation while
    /// queued is honored once the permit is held: the waiter throws before
    /// `body` runs and hands the permit on, so a cancelled waiter never
    /// inherits another account's prompt turn and never sticks in the queue.
    func run<T: Sendable>(_ body: @Sendable () async -> T) async throws -> T {
        try Task.checkCancellation()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return await body()
    }

    /// Takes the permit, suspending in FIFO order while held.
    private func acquire() async {
        if holders == 0 {
            holders = 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the permit to the next waiter, or releases it.
    private func release() {
        if waiters.isEmpty {
            holders = 0
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - CLI runner

/// Outcome of one `op` spawn as plain data.
///
/// Ports the executor's `OpCliResult` (`sdk/op-cli.ts`): the spawn never
/// throws — the provider owns failure typing. `stdout` carries the payload;
/// `message` carries stderr or the spawn failure for internal diagnosis and
/// never reaches a thrown error.
struct OnePasswordSpawnOutcome: Sendable {
    /// The child exited zero within budget and output fit the cap.
    let ok: Bool
    /// The child was killed by the spawn timeout (or the budget was empty).
    let timedOut: Bool
    /// Output exceeded the byte cap; the child was killed.
    let oversized: Bool
    /// `op` could not be launched at all.
    let cliMissing: Bool
    /// Raw stdout bytes.
    let stdout: Data
    /// Internal-only diagnostics, never thrown.
    let message: String

    /// Failure shape for awaiting-task cancellation. Callers re-check
    /// cancellation after the spawn, so this outcome never surfaces: resolve
    /// throws `CancellationError` and health reports unhealthy.
    static let cancelled = OnePasswordSpawnOutcome(
        ok: false, timedOut: false, oversized: false,
        cliMissing: false, stdout: Data(), message: "cancelled"
    )
}

/// Raw `op` spawn boundary.
///
/// The spawn is async on purpose: a synchronous wait would pin a cooperative
/// thread, and an `op` stuck on a 1Password approval prompt would stall the
/// pool until answered (the executor's `sdk/op-cli.ts` rationale). Output
/// drains through readability handlers under a byte cap; the timeout kills
/// the child; task cancellation terminates it. stdout carries the payload and
/// stderr the CLI's diagnostics, so a non-zero exit reports stderr when
/// present.
enum OnePasswordCLIRunner {
    /// Runs `op` once.
    static func exec(
        command: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: Double
    ) async -> OnePasswordSpawnOutcome {
        let box = OnePasswordSpawnBox(maximumBytes: OnePasswordSecretsProvider.maximumOutputBytes)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (
                continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>
            ) in
                box.begin(
                    continuation: continuation, command: command,
                    arguments: arguments, environment: environment,
                    timeoutSeconds: timeoutSeconds
                )
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Resolves `command` to a runnable path: a value containing `/` is used
    /// directly, else each `PATH` segment is tried in order. Production
    /// always passes the allowlisted spawn environment's pinned `PATH`,
    /// so a bare `op` resolves against allowlisted dirs only.
    static func resolveExecutable(
        command: String, pathValue: String?, isExecutable: (String) -> Bool
    ) -> String? {
        if command.contains("/") {
            return isExecutable(command) ? command : nil
        }
        guard let pathValue else { return nil }
        for directory in pathValue.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Finish reason for one spawn. Internal: the provider maps outcomes to typed
/// errors, so reasons never surface beyond this file.
private enum OnePasswordFinishKind: Sendable {
    /// The child terminated with this status, after both EOFs landed.
    case exited(status: Int32)
    /// Stdout exceeded the cap; the child was killed.
    case oversized
    /// The spawn timeout killed the child, or the budget was empty.
    case timedOut
    /// No runnable `op` was found.
    case cliMissing
    /// The child could not be launched.
    case spawnFailed(message: String)
    /// The awaiting task was cancelled.
    case cancelled
}

/// Lock-guarded spawn state: the single resume, the child, and the drained
/// output. Every finish path funnels through `finish`, which resumes at most
/// once and releases the child, pipes, handlers, and timeout task.
final class OnePasswordSpawnBox: @unchecked Sendable {
    /// Largest stdout kept before the child is killed.
    private let maximumBytes: Int
    /// Guards every mutable field below.
    private let lock = NSLock()
    /// Awaiting resume, taken exactly once by `finish`.
    private var continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>?
    /// Running child, cleared by `finish`.
    private var process: Process?
    /// Live pipes, cleared by `finish`.
    private var pipes: [Pipe] = []
    /// Drained stdout.
    private var output = Data()
    /// Drained stderr tail, bounded branch-free.
    private var errorOutput = Data()
    /// Set once `finish` has run; every later finish is a no-op.
    private var finished = false
    /// Child exit status once reaped; nil while running.
    private var terminationStatus: Int32?
    /// Stdout hit EOF.
    private var stdoutEOF = false
    /// Stderr hit EOF.
    private var stderrEOF = false
    /// Pending timeout kill, cancelled by `finish`.
    private var timeoutTask: Task<Void, Never>?
    /// Test seam: invoked after the child is tracked but before it launches,
    /// so cancellation-in-the-window tests can land a cancel deterministically.
    /// Nil in production. Set before `begin` runs; never mutated after.
    var launchGate: (@Sendable () -> Void)?
    /// Process identifier of the launched child, recorded by the parent
    /// right after `run` returns. A promptly-reaped child may die before
    /// first scheduling, so child-side logging cannot prove the launch
    /// happened; this parent-side record can.
    private var launchedPID: Int32?

    /// The launched child's PID, once `begin` has launched. Test
    /// observability for the track-then-launch race; nil until launch.
    var launchedChildPID: Int32? {
        lock.withLock { launchedPID }
    }

    /// Assembles spawn state with a stdout cap of `maximumBytes`.
    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    /// Launches the child and arms the timeout kill. Empty budgets and
    /// missing executables finish without spawning. A cancel that landed
    /// before `begin` (already-cancelled task: the cancellation handler runs
    /// first) resumes the late continuation as cancelled without spawning —
    /// otherwise the continuation would never resume and the task would hang.
    func begin(
        continuation: CheckedContinuation<OnePasswordSpawnOutcome, Never>,
        command: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: Double
    ) {
        let preFinished: Bool = lock.withLock {
            if finished { return true }
            self.continuation = continuation
            return false
        }
        if preFinished {
            continuation.resume(returning: OnePasswordSpawnOutcome.cancelled)
            return
        }
        guard timeoutSeconds > 0 else {
            finish(kind: .timedOut)
            return
        }
        guard let executable = OnePasswordCLIRunner.resolveExecutable(
            command: command,
            pathValue: environment["PATH"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else {
            finish(kind: .cliMissing)
            return
        }
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        // Empty availableData is EOF: the source refires until detached,
        // so detach here instead of spinning on the lock.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                handle.readabilityHandler = nil
                self.noteStdoutEOF()
                return
            }
            self.appendOutput(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                handle.readabilityHandler = nil
                self.noteStderrEOF()
                return
            }
            self.appendError(data)
        }
        process.terminationHandler = { finished in
            self.noteTerminated(status: finished.terminationStatus)
        }
        lock.withLock {
            self.process = process
            self.pipes = [outPipe, errPipe]
        }
        launchGate?()
        do {
            try process.run()
        } catch {
            finish(kind: .spawnFailed(message: String(describing: error)))
            return
        }
        lock.withLock { launchedPID = process.processIdentifier }
        reapUntrackedLaunch(process)
        armOrAbandon(limit: timeoutSeconds)?.terminate()
    }

    /// Reaps a just-launched child the box no longer tracks. A cancel that
    /// landed between tracking the child above and the launch just now
    /// finished the box while `terminate` still saw an unlaunched task (a
    /// no-op by the `isRunning` gate), so the launch that just succeeded is
    /// untracked: terminate the local here, where the launch is known good.
    /// Pending boxes keep the child: tracking and the timeout arm below
    /// proceed as usual. Terminating an exited child is a no-op.
    func reapUntrackedLaunch(_ process: Process) {
        let abandoned: Bool = lock.withLock { finished }
        if abandoned {
            process.terminate()
        }
    }

    /// Arms the timeout kill for the tracked child. A cancel (or instant
    /// exit) that finished the box between the spawn and here must leave
    /// neither a stray timeout task retaining the box nor an untracked live
    /// child, so this is one critical section: either the box is still
    /// pending and the kill is armed (nil), or the child is untracked and
    /// returned for the caller to terminate outside the lock. Retained
    /// pipes need no detach here: their handlers self-detach on the EOF
    /// the terminated child produces.
    func armOrAbandon(limit: Double) -> Process? {
        var stray: Process?
        lock.withLock {
            if finished {
                stray = self.process
                self.process = nil
            } else {
                timeoutTask = Task {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(min(limit, 1_000_000) * 1_000_000_000)
                        )
                    } catch {
                        return
                    }
                    self.noteTimeout()
                }
            }
        }
        return stray
    }

    /// Records child termination. The exit only completes once both pipes
    /// hit EOF (see `maybeFinishExited`).
    func noteTerminated(status: Int32) {
        lock.withLock { terminationStatus = status }
        maybeFinishExited()
    }

    /// Records stdout EOF.
    func noteStdoutEOF() {
        lock.withLock { stdoutEOF = true }
        maybeFinishExited()
    }

    /// Records stderr EOF.
    func noteStderrEOF() {
        lock.withLock { stderrEOF = true }
        maybeFinishExited()
    }

    /// Completes a voluntary exit once the exit status plus both EOFs have
    /// landed, in any order. Data callbacks race termination on separate
    /// queues, so snapshotting output at termination can truncate the
    /// payload; waiting for both EOFs keeps every drained byte.
    private func maybeFinishExited() {
        let status: Int32? = lock.withLock {
            if stdoutEOF, stderrEOF, let terminated = terminationStatus {
                return terminated
            }
            return nil
        }
        guard let status else { return }
        finish(kind: .exited(status: status))
    }

    /// Kills the child for exceeding its budget.
    func noteTimeout() {
        terminate()
        finish(kind: .timedOut)
    }

    /// Kills the child for awaiting-task cancellation.
    func cancel() {
        terminate()
        finish(kind: .cancelled)
    }

    /// Drains stdout, killing the child and finishing oversized past the
    /// cap. Finishes immediately instead of waiting for EOF: a blocked
    /// grandchild can hold the pipes open after the kill.
    func appendOutput(_ data: Data) {
        let overLimit: Bool = lock.withLock {
            output.append(data)
            return output.count > maximumBytes
        }
        if overLimit {
            terminate()
            finish(kind: .oversized)
        }
    }

    /// Drains stderr, keeping the tail bounded.
    func appendError(_ data: Data) {
        lock.withLock {
            errorOutput = (errorOutput + data).suffix(maximumBytes)
        }
    }

    /// Terminates the child when launched and still running. The launch
    /// itself races cancellation: `begin` tracks the child before `run`,
    /// so a cancel landing in between must not terminate a never-launched
    /// task — Foundation raises `NSInvalidArgumentException` there and
    /// aborts the host. The `isRunning` gate makes that path a no-op;
    /// `reapUntrackedLaunch` terminates the child once launched instead.
    /// Idempotent: terminating an exited child is a no-op.
    private func terminate() {
        lock.withLock {
            if process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    /// Resumes the awaiting spawn exactly once.
    private func finish(kind: OnePasswordFinishKind) {
        let pending: (OnePasswordSpawnOutcome, CheckedContinuation<OnePasswordSpawnOutcome, Never>?)? =
            lock.withLock {
                guard finished == false else { return nil }
                finished = true
                timeoutTask?.cancel()
                timeoutTask = nil
                process?.terminationHandler = nil
                for pipe in pipes {
                    pipe.fileHandleForReading.readabilityHandler = nil
                }
                pipes = []
                process = nil
                let taken = continuation
                continuation = nil
                let out = output
                let err = errorOutput
                let result: (ok: Bool, timedOut: Bool, oversized: Bool, cliMissing: Bool, message: String)
                switch kind {
                case .exited(let status):
                    if status == 0 {
                        result = (true, false, false, false, "")
                    } else {
                        let raw = String(data: err, encoding: .utf8) ?? ""
                        let detail = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if detail.isEmpty {
                            result = (false, false, false, false, "1Password CLI failed")
                        } else {
                            result = (false, false, false, false, detail)
                        }
                    }
                case .oversized:
                    result = (false, false, true, false, "1Password CLI output exceeded its limit")
                case .timedOut:
                    result = (false, true, false, false, "1Password CLI timed out")
                case .cliMissing:
                    result = (false, false, false, true, "1Password CLI is not installed")
                case .spawnFailed(let message):
                    result = (false, false, false, true, message)
                case .cancelled:
                    return (OnePasswordSpawnOutcome.cancelled, taken)
                }
                return (
                    OnePasswordSpawnOutcome(
                        ok: result.ok, timedOut: result.timedOut, oversized: result.oversized,
                        cliMissing: result.cliMissing, stdout: out, message: result.message
                    ),
                    taken
                )
            }
        guard let (outcome, continuation) = pending else { return }
        continuation?.resume(returning: outcome)
    }
}
