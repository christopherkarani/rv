import Foundation
import RVDomain
import RVPolicy
import Synchronization

/// Fresh unguessable identifier for one host-prepared operation.
///
/// Minted by the workspace host at preparation; never selected by the CLI
/// and never derived from the intent digest (a deterministic derivation
/// would let anyone recompute live IDs from public digests). `init()`
/// always mints. `init(rawValue:)` only names an identifier the host
/// already minted. Naming one grants nothing: knowledge of an ID yields at
/// most a safe description, never execution.
public struct PreparedLaunchID: Hashable, Sendable, Equatable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Destination/lifecycle binding of one prepared operation: which
/// workspace, on which host incarnation, under which preparation.
///
/// Kept separate from `WorkspaceLaunchIntent` (the semantic *what*) by
/// construction: this is the envelope's *where/who/when*. A host restart
/// is a new process with an empty store, so old bindings can never
/// validate; prepared operations are never restored from journals.
struct PreparedLaunchBinding: Hashable, Sendable, Equatable {
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let preparedLaunchID: PreparedLaunchID
}

/// Filesystem identity of the prepared cwd, captured at preparation and
/// re-verified live at redemption commit.
///
/// The resolved path string closes symlink-target swaps and renames that
/// change resolution; the device/inode pair closes same-path recreation;
/// the mount source closes volume replacement that recycles device
/// numbers. All are captured from the live filesystem at prepare time;
/// redemption compares a fresh live capture for equality. Preparation
/// additionally anchors the device to the boundary volume, so a swap
/// planted before preparation is refused rather than adopted as truth.
/// No secret or authority value: host-local filesystem facts, never sent
/// over the wire.
struct CwdIdentityStamp: Hashable, Sendable, Equatable {
    let resolvedPath: String
    let device: UInt64
    let inode: UInt64
    let mountSource: String
}

#if os(macOS)
/// Captures the live cwd identity for `policyWorkspace`: POSIX-realpath
/// resolution (reusing the vetted preparation helper, including its
/// existence and safety checks) plus the device/inode and mount source of
/// the resolved directory. Nil on any failure: callers fail closed.
func captureCwdIdentity(policyWorkspace: WorkingDirectory) -> CwdIdentityStamp? {
    guard case .success(let resolved) = existingResolvedWorkspacePath(policyWorkspace),
        let identity = workspacePathIdentity(resolved),
        identity.isDirectory,
        let mountSource = workspaceMountSource(resolved)
    else {
        return nil
    }
    return CwdIdentityStamp(
        resolvedPath: resolved, device: identity.device, inode: identity.inode,
        mountSource: mountSource)
}

/// Re-verifies the live cwd identity against a retained stamp: resolves
/// the policy workspace fresh and requires the full stamp (resolved path,
/// device, inode, mount source) to match. Pure filesystem observation;
/// false on any error. Used at accept, at spawn commit, and inside the
/// spawn body immediately around `posix_spawn`.
func verifyLiveCwdIdentity(
    policyWorkspacePath: String,
    expected: CwdIdentityStamp
) -> Bool {
    guard let policy = WorkingDirectory(validating: policyWorkspacePath),
        let live = captureCwdIdentity(policyWorkspace: policy),
        live == expected
    else {
        return false
    }
    return true
}
#endif

/// Frozen effective environment for one prepared launch, exactly as
/// `execve` will receive it.
///
/// Entries are complete `"name=value"` strings in spawn order (first
/// spelling wins at lookup, so order is significant and preserved).
/// Frozen at preparation from a host-environment snapshot plus retained
/// productive/profile/egress facts; dispatch passes them verbatim and
/// never re-resolves. Values are host-private: only `digestHex` (a
/// non-secret immutable identity) ever leaves the retained object for
/// descriptions. Identity launches stage no credentials, so no secret
/// value can appear here; credential-bearing shapes are rejected before
/// any snapshot exists.
struct WorkspaceLaunchEnvironmentSnapshot: Sendable, Equatable {
    /// Ordered `"name=value"` entries, frozen at preparation.
    let entries: [String]
    /// SHA-256 over the canonical encoding below, as lowercase hex.
    let digestHex: String

    init(entries: [String]) {
        self.entries = entries
        self.digestHex = RVDigest.sha256Hex(Self.canonicalBytes(entries))
    }

    /// Domain-separated length-framed encoding. Same discipline as the
    /// intent projection: `str` is u32 big-endian length plus exact bytes,
    /// fixed order, entries in spawn order (never sorted: order affects
    /// `execve` lookup). Encode-only; nothing parses these bytes.
    ///
    /// Layout: `str domain ‖ u32 version ‖ u32 count ‖ count × str entry`.
    static func canonicalBytes(_ entries: [String]) -> [UInt8] {
        var out: [UInt8] = []
        appendString(&out, "RV.WorkspaceLaunchEnvironmentSnapshot.v1")
        appendU32(&out, 1)
        appendU32(&out, UInt32(entries.count))
        for entry in entries {
            appendString(&out, entry)
        }
        return out
    }

    /// Total UTF-8 payload size, for the preparation bound.
    var totalBytes: Int {
        entries.reduce(0) { $0 + $1.utf8.count }
    }

    private static func appendU32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendString(_ out: inout [UInt8], _ value: String) {
        let bytes = Array(value.utf8)
        appendU32(&out, UInt32(bytes.count))
        out.append(contentsOf: bytes)
    }
}

/// The exact immutable execution object the host prepared.
///
/// This is what will eventually be reviewed (via its intent), authorized
/// (via a future permit), and dispatched — or invalidated. It owns every
/// input dispatch needs, so dispatch performs no re-resolution: no
/// definition lookup, no link lookup, no profile selection, no cwd choice,
/// no argv parsing, no environment resolution.
///
/// This is NOT wire authority, NOT `Codable` authority (deliberately not
/// `Codable`), NOT an `AgentInstance`, and NOT a permit. Only the
/// host process holds instances; clients can never name one into
/// existence, and the store reveals only `PreparedLaunchDescription`.
struct PreparedWorkspaceLaunch: Sendable, Equatable {
    /// Destination/lifecycle envelope.
    let binding: PreparedLaunchBinding
    /// Client request correlation, when the proposal carried one. Not
    /// authority; duplicate client IDs still mint distinct preparations.
    let requestID: UUID?
    /// The PR1 semantic object: exactly what the human will review.
    let intent: WorkspaceLaunchIntent
    /// Digest of `intent`, computed once at preparation.
    let intentDigest: WorkspaceLaunchIntentDigest
    let preparedAt: Date
    /// Absolute expiry. Lookups at or after this instant fail.
    let expiresAt: Date
    // MARK: - Retained execution state (host-private)
    /// Exact trusted selection. Never re-resolved after this point.
    let selection: ResolvedAgentLaunch
    /// Exact validated command (executable + ordered argv).
    let command: IsolatedCommand
    /// POSIX-realpath-resolved cwd, as the spawn will chdir to it.
    let resolvedWorkspacePath: String
    /// Live filesystem identity of the cwd at preparation. Redemption
    /// re-captures the live identity and requires equality before the
    /// prepared→accepted transition and again at spawn commit.
    let cwdIdentity: CwdIdentityStamp
    /// Initial stdio configuration (discard or PTY + window).
    let io: IsolatedIO
    /// Frozen effective environment, passed verbatim at dispatch.
    let environment: WorkspaceLaunchEnvironmentSnapshot
    /// Retained productive-workspace facts (PATH value, developer home,
    /// grants). Never re-resolved at dispatch.
    let productive: ProductiveWorkspaceResolution
    /// Compiled launch request: Seatbelt profile, manifest (with its
    /// preparation-minted private home), plan, and productive facts.
    let launchRequest: IsolatedLaunchRequest
    /// Retained egress proxy port (nil when the proxy failed to bind).
    let egressProxyPort: Int?
    /// Integration metadata from the trusted definition (named) or nil
    /// (custom). Never taken from the wire for identity launches.
    /// Step 8 (F2): `stagingAgent` is definition-derived only — the sole
    /// trusted credential-selection input, typed so wire tags, HookHost
    /// values, and CLI/caller-provided names are unrepresentable here.
    let hook: HookHost?
    let stagingAgent: DefinitionStagingTag?
    // No keychain field exists: identity launches stage no credentials,
    // so there is nothing to retain and no reader to consult.

    /// Safe descriptive projection. Values that must stay host-private
    /// (environment entries, retained state) never appear here.
    var description: PreparedLaunchDescription {
        PreparedLaunchDescription(
            binding: binding,
            requestID: requestID,
            intent: intent,
            intentDigest: intentDigest,
            environmentDigestHex: environment.digestHex,
            preparedAt: preparedAt,
            expiresAt: expiresAt
        )
    }
}

/// Safe description of a prepared operation for future `rvd`/UI use.
///
/// Descriptive only: possession grants no authority. Exposes digests and
/// bindings, never `RuntimeCapability`, owner tokens, secret environment
/// values, credentials, or private host state. Arguments stay structured
/// inside the intent; nothing here joins them into shell text.
struct PreparedLaunchDescription: Sendable, Equatable {
    let binding: PreparedLaunchBinding
    let requestID: UUID?
    let intent: WorkspaceLaunchIntent
    let intentDigest: WorkspaceLaunchIntentDigest
    let environmentDigestHex: String
    let preparedAt: Date
    let expiresAt: Date
}

/// Bounds for host-owned prepared-operation state.
enum PreparedLaunchLimits {
    /// Maximum live prepared operations per workspace host. Mirrors
    /// `WorkspaceControlLimits.maxRuntimes`: preparation must stay within
    /// the same order as execution.
    static let maxPendingPreparedLaunches = 64
    /// Preparation lifetime. Covers a human review window; freshness is
    /// re-verified at redemption regardless, so expiry bounds staleness,
    /// not authority. No repository equivalent exists; this value is new.
    static let timeToLiveSeconds: TimeInterval = 900
    /// Maximum total UTF-8 bytes of one frozen environment. Far above any
    /// real environment; prevents pathological memory use from an
    /// unexpected host state. No repository equivalent exists.
    static let maxFrozenEnvironmentBytes = 1_048_576
    /// Maximum recorded redemption results per workspace host. Same order
    /// as the prepared-operation bound; oldest entries are evicted first.
    static let maxRedemptionResults = 64
}

/// Recorded outcome of one accepted redemption, keyed by authorization ID.
///
/// Monotonic history: once recorded, an entry never changes, so a replayed
/// commit (lost reply, duplicate delivery) returns the original outcome
/// instead of dispatching again. Carries identifiers for audit attribution
/// only — never capabilities, secrets, or environment values.
enum RecordedRedemptionResult: Sendable, Equatable {
    case launched(runtime: RuntimeSessionID, instance: AgentInstanceID)
    case failed
}

/// Typed preparation failure. Nothing is stored, spawned, or minted on
/// any of these paths.
enum PreparedLaunchError: Error, Sendable, Equatable {
    /// Workspace lifecycle is not active. No process was spawned.
    case workspaceNotActive
    /// Named selection revision is not the digest of its definition.
    case revisionMismatch
    /// Custom selection is not the fixed ad-hoc template for its digest.
    case invalidCustomSnapshot
    /// The selection's effective profile does not correspond to the
    /// verified revision: named selections must carry exactly the
    /// definition's revision-committed profile, custom selections must
    /// carry nil (base fence). Anything else could execute grants the
    /// bound revision never attested.
    case resourceProfileMismatch
    /// The selection stages credentials. Secrets integration is deferred;
    /// such shapes cannot be prepared yet.
    case credentialStagingNotSupported
    /// Executable/argv failed `IsolatedCommand` validation.
    case invalidCommand
    /// `.inherit` stdio can never be prepared (in-process door only).
    case unsupportedIO
    /// Profile compilation, workspace resolution, inode scan, or manifest
    /// construction failed. No process was spawned.
    case preparationFailed(IsolationApplyError)
    /// Frozen environment exceeds the size bound.
    case environmentTooLarge
    /// Retained inputs failed PR1 intent validation. No digest exists.
    case invalidIntent(WorkspaceLaunchIntentError)
    /// Store holds the maximum live preparations (after evicting expired).
    case storeFull
}

/// Ephemeral host-owned prepared-operation state.
///
/// In-memory only, keyed by `PreparedLaunchID`, bounded in count and
/// lifetime. Dies with the process; never restored from journals. The
/// acceptance fence lives here: a prepared entry moves to `accepted`
/// at most once, inside the supervisor's spawn-commit critical section,
/// and never returns to `prepared` — not on spawn failure, not on
/// invalidation, not on close. Recorded redemption results are monotonic
/// history for replay-safe replies.
///
/// Concurrency: all mutation serializes on one lock. The supervisor nests
/// store operations inside its lifecycle lock (ordering: lifecycle, then
/// store) so preparation racing workspace closure can neither resurrect
/// entries nor dispatch after close.
///
/// The store never returns retained execution state except through
/// `accept`, which only the supervisor's redemption path calls after
/// verifying an authenticated commit: every other lookup yields
/// `PreparedLaunchDescription` or a boolean probe. Knowing an ID
/// therefore cannot launch anything.
final class PreparedLaunchStore: Sendable {
    private struct State: Sendable {
        var entries: [UUID: PreparedWorkspaceLaunch] = [:]
        var accepted: Set<UUID> = []
        var results: [UUID: RecordedRedemptionResult] = [:]
        var resultOrder: [UUID] = []
    }

    private let state: Mutex<State>

    init() {
        self.state = Mutex(State())
    }

    /// Stores one preparation. Evicts expired entries first, then refuses
    /// when full or when the ID already exists (duplicate IDs are
    /// impossible from UUID minting; the check is defense in depth so an
    /// old ID can never identify a newly prepared operation).
    func insert(_ prepared: PreparedWorkspaceLaunch, now: Date) -> Bool {
        state.withLock { state in
            state.entries = state.entries.filter { $0.value.expiresAt > now }
            let key = prepared.binding.preparedLaunchID.rawValue
            guard state.entries[key] == nil,
                state.entries.count < PreparedLaunchLimits.maxPendingPreparedLaunches
            else {
                return false
            }
            state.entries[key] = prepared
            return true
        }
    }

    /// Safe description, or nil when absent or expired. Never returns
    /// retained execution state.
    func description(for id: PreparedLaunchID, now: Date) -> PreparedLaunchDescription? {
        state.withLock { state in
            guard let prepared = state.entries[id.rawValue], prepared.expiresAt > now else {
                return nil
            }
            return prepared.description
        }
    }

    /// Freshness probe for dispatch: present and unexpired. Returns no
    /// state, so it cannot become a dispatch-by-ID oracle. Accepted entries
    /// are no longer prepared and report unusable here.
    func isUsable(_ id: PreparedLaunchID, now: Date) -> Bool {
        state.withLock { state in
            guard let prepared = state.entries[id.rawValue] else {
                return false
            }
            return prepared.expiresAt > now
        }
    }

    /// Atomically moves one prepared entry to `accepted` and returns its
    /// retained execution state — the single linearization point of host
    /// redemption. Nil (without mutation, except dropping an expired entry)
    /// when the entry is absent, expired, already accepted, the live cwd
    /// identity differs from the retained stamp, or the predicate fails.
    ///
    /// The caller must hold the supervisor lifecycle lock: accept runs in a
    /// lifecycle-serialized section, and the spawn-commit section later
    /// re-checks acceptance adjacent to the close/lifecycle check and
    /// `posix_spawn`. The predicate must be pure (no I/O): it receives the
    /// retained entry and checks exact binding/digest/kind/definition
    /// correspondence with the commit.
    ///
    /// Host-private: only the supervisor's redemption path calls this, and
    /// only for a commit that arrived over the authenticated service
    /// channel. There is no dispatch-by-ID.
    func accept(
        _ id: PreparedLaunchID,
        now: Date,
        liveCwd: CwdIdentityStamp,
        verifying predicate: (PreparedWorkspaceLaunch) -> Bool
    ) -> PreparedWorkspaceLaunch? {
        state.withLock { state in
            guard let prepared = state.entries[id.rawValue] else {
                return nil
            }
            guard prepared.expiresAt > now else {
                state.entries[id.rawValue] = nil
                return nil
            }
            guard prepared.cwdIdentity == liveCwd, predicate(prepared) else {
                return nil
            }
            state.entries[id.rawValue] = nil
            state.accepted.insert(id.rawValue)
            return prepared
        }
    }

    /// True between `accept` and the recording of that acceptance's
    /// outcome. Neither `remove` nor `invalidateAll` clears it, so an
    /// acceptance can never be re-armed into a second dispatch; only
    /// `recordResult` clears it, atomically with publishing the outcome
    /// that supersedes it.
    func isAccepted(_ id: PreparedLaunchID) -> Bool {
        state.withLock { state in
            state.accepted.contains(id.rawValue)
        }
    }

    /// Records the terminal outcome of one accepted redemption and clears
    /// its acceptance marker atomically. First write wins: replays return
    /// the original outcome. Bounded FIFO: oldest entries are evicted
    /// first (mirroring the service, which likewise forgets ancient
    /// consumed operations: a replay older than the window reports
    /// unknown rather than the evicted outcome).
    ///
    /// Clearing the marker at record time bounds markers to in-flight
    /// acceptances: a duplicate always observes the marker (in flight) or
    /// the recorded outcome (finished), never neither.
    func recordResult(
        authorization: UUID,
        preparedID: PreparedLaunchID,
        result: RecordedRedemptionResult
    ) {
        state.withLock { state in
            guard state.results[authorization] == nil else { return }
            state.results[authorization] = result
            state.accepted.remove(preparedID.rawValue)
            state.resultOrder.append(authorization)
            while state.resultOrder.count > PreparedLaunchLimits.maxRedemptionResults {
                let oldest = state.resultOrder.removeFirst()
                state.results[oldest] = nil
            }
        }
    }

    /// Previously recorded outcome for one authorization, if any. A hit
    /// means the authorization is spent: the caller must reply with the
    /// recorded outcome, never dispatch.
    func recordedResult(authorization: UUID) -> RecordedRedemptionResult? {
        state.withLock { state in
            state.results[authorization]
        }
    }

    /// Removes one prepared entry. Idempotent. Never touches `accepted`:
    /// invalidation cannot un-accept a committed redemption.
    func remove(_ id: PreparedLaunchID) {
        state.withLock { state in
            state.entries[id.rawValue] = nil
        }
    }

    /// Drops every prepared entry. Called on workspace closure; entries
    /// never reappear afterward because preparation re-checks lifecycle
    /// first. Accepted markers survive close (an in-flight acceptance
    /// stays fenced) and recorded results survive as monotonic history;
    /// neither is launchable state.
    func invalidateAll() {
        state.withLock { state in
            state.entries.removeAll()
        }
    }

    /// Drops expired entries. Returns the number removed.
    @discardableResult
    func pruneExpired(now: Date) -> Int {
        state.withLock { state in
            let before = state.entries.count
            state.entries = state.entries.filter { $0.value.expiresAt > now }
            return before - state.entries.count
        }
    }

    /// Live (unexpired) entry count at `now`. For tests and debugging.
    func liveCount(now: Date) -> Int {
        state.withLock { state in
            state.entries.values.filter { $0.expiresAt > now }.count
        }
    }

    /// Accepted-marker count. For tests and debugging.
    func acceptedCount() -> Int {
        state.withLock { state in
            state.accepted.count
        }
    }

    /// Recorded-result count. For tests and debugging.
    func resultCount() -> Int {
        state.withLock { state in
            state.results.count
        }
    }
}

/// Verified selection kind: named definitions resolve through the trusted
/// store; the reserved snapshot id always means a custom launch.
enum PreparedSelectionKind: Sendable, Equatable {
    case named(AgentDefinition)
    case custom(expectedContentDigestSHA256: String)
}

/// Verifies a trusted selection before preparation freezes it.
///
/// Named: the revision must equal the recomputed digest of the
/// definition, so the retained selection provably corresponds to the
/// bound revision. Custom: the definition must equal the fixed ad-hoc
/// template rebuilt from its own pinned digest, and the revision must
/// match that template. Anything else fails closed: preparation never
/// freezes an inconsistent pair.
func verifyPreparedSelection(
    _ selection: ResolvedAgentLaunch
) -> Result<PreparedSelectionKind, PreparedLaunchError> {
    let definition = selection.resolved.definition
    let revision = selection.resolved.revision
    if definition.id.rawValue == AgentDefinitionStore.reservedSnapshotID {
        guard let digest = definition.executableRequirement.expectedContentDigestSHA256,
            let snapshot = AdHocAgentSnapshot.make(expectedContentDigestSHA256: digest),
            snapshot.definition == definition,
            snapshot.revision == revision
        else {
            return .failure(.invalidCustomSnapshot)
        }
        return .success(.custom(expectedContentDigestSHA256: digest))
    }
    guard revision == AgentDefinitionRevision.resolve(definition) else {
        return .failure(.revisionMismatch)
    }
    return .success(.named(definition))
}

/// The revision-committed effective profile for a verified selection:
/// the definition's own profile for named launches (which the revision
/// pins in full), nil for custom launches (base fence, always). Fails
/// closed when the selection's carried profile diverges from it, so
/// preparation never freezes grants the bound revision never attested.
func committedEffectiveProfile(
    kind: PreparedSelectionKind,
    selection: ResolvedAgentLaunch
) -> Result<RuntimeResourceProfile?, PreparedLaunchError> {
    switch kind {
    case .named(let definition):
        guard selection.resourceProfile == definition.resourceProfile else {
            return .failure(.resourceProfileMismatch)
        }
        return .success(selection.resourceProfile)
    case .custom:
        guard selection.resourceProfile == nil else {
            return .failure(.resourceProfileMismatch)
        }
        return .success(nil)
    }
}

/// True when neither the definition nor the effective profile stages
/// credentials: no binding names, no credential copies, no keychain
/// entries. Preparation rejects anything else until Secrets exists.
func isCredentialFreeSelection(_ selection: ResolvedAgentLaunch) -> Bool {
    let definition = selection.resolved.definition
    guard definition.credentialBindings.isEmpty,
        definition.resourceProfile.credentials.isEmpty,
        definition.resourceProfile.keychain.isEmpty
    else {
        return false
    }
    if let profile = selection.resourceProfile {
        guard profile.credentials.isEmpty, profile.keychain.isEmpty else {
            return false
        }
    }
    return true
}

/// Maps spawn stdio to the closed intent IO vocabulary. `.inherit` has
/// no intent form and can never be prepared.
func preparedLaunchIO(from io: IsolatedIO) -> WorkspaceLaunchIO? {
    switch io {
    case .discard:
        .discard
    case .pseudoTerminal(let rows, let columns):
        .pseudoTerminal(rows: rows, columns: columns)
    case .inherit:
        nil
    }
}
