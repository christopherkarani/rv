import Foundation
import OrderedCollections
import RVDomain

/// Step 8B.1 sole authority for allow-once grants: service-held, ephemeral,
/// consume-once state. The daemon owns one instance for its process lifetime;
/// a restart (or a fresh instance) invalidates every outstanding grant.
///
/// Plants arrive ONLY from trusted human-approval completions: the operator-UI
/// hook ceremony (`HookAskResolver`) and genuine-CLI TTY attestation (pinned
/// `.cli` component role + in-binary TTY/code/LocalAuthentication checks).
/// The `allow-once.jsonl` file is a display/audit projection: reading,
/// modifying, deleting, or re-appending it never creates, restores, or
/// replays authority (B-F1/B-F3).
///
/// Binding per grant: exact canonical-action fingerprint (view folded with
/// the erased invocation prefix: wrappers, assignments, argv0 path) +
/// canonical cwd + issuing epoch + strict expiry + atomic single-use. The
/// issuing pending-approval ID and ceremony code hash are recorded for audit
/// and double-attest defense. No continuation token is claimed: host
/// protocols cannot establish one, so a grant authorizes one re-issue of
/// the exact action, nothing else.
///
/// M-07: the fingerprint covers the masked view only, so same-view commands
/// with different hidden payloads would share authority. Bound grants also
/// carry a payload digest of the exact masked segments; spend recomputes
/// and requires equality. Hook-ceremony plants bind `.salted`, a digest
/// under a per-table random salt. TTY attestation plants bind `.content`,
/// the unsalted content digest the genuine CLI reviewed (the daemon never
/// sees exact text there, so no salted digest is computable). `.unbound`
/// grants (legacy rows without a digest) keep legacy behavior for
/// known-unmasked spends and fail closed on masked spends. The salt and
/// the segments never leave this actor.
public actor EphemeralAllowOnceTable {
    public struct Grant: Sendable, Equatable {
        public let fingerprint: GrantFingerprint
        public let cwd: WorkingDirectory
        public let codeHash: CodeHash
        public let pendingID: ApprovalID?
        public let createdAt: Date
        public let expiresAt: Date
        /// The grant's one payload binding: unbound (legacy), salted
        /// (hook ceremony), or content (TTY attestation). Exactly one by
        /// construction; a both-bound grant does not compile.
        public let binding: PayloadBinding

        public init(
            fingerprint: GrantFingerprint,
            cwd: WorkingDirectory,
            codeHash: CodeHash,
            pendingID: ApprovalID? = nil,
            createdAt: Date,
            expiresAt: Date,
            binding: PayloadBinding = .unbound
        ) {
            self.fingerprint = fingerprint
            self.cwd = cwd
            self.codeHash = codeHash
            self.pendingID = pendingID
            self.createdAt = createdAt
            self.expiresAt = expiresAt
            self.binding = binding
        }
    }

    public enum PlantResult: Sendable, Equatable {
        case planted
        /// This ceremony code already planted this epoch: a double-attest
        /// (or a replayed attestation) creates no second grant.
        case alreadyRedeemed
        /// Invalid input (empty view or code hash), or a full table.
        /// Never a grant.
        case refused
    }

    /// Issuing epoch. Restarts mint a fresh table (fresh epoch); grants never
    /// cross epochs because the table itself does not survive the process.
    public nonisolated let epoch: UUID

    /// Maximum grant lifetime. Matches the legacy file-grant window so the
    /// remediation changes the trust root, not the product TTL.
    public static let maxTTL: TimeInterval = 24 * 60 * 60

    /// Maximum live grants. Plants past a full table are refused (fail
    /// closed; the human retries). The cap also bounds the linear spend
    /// scan in `consume`/`hasGrant`.
    public static let maxGrants = 1024
    /// M2: redeemed-code retention cap. Codes stay single-use for the
    /// table lifetime (a replayed attestation after grant expiry must
    /// not plant a fresh grant without a human); past the cap the
    /// oldest markers evict FIFO, which is the documented residual:
    /// only an ancient (evicted) code can ever re-plant.
    public static let maxRedeemedCodes = 4096

    private var grants: [UUID: Grant] = [:]
    /// Ceremony codes that already planted, with the date they planted
    /// (audit only — never an expiry). Retained for the table lifetime
    /// and evicted FIFO past `maxRedeemedCodes`, never pruned by grant
    /// expiry: expiry-pruning let a replayed attestation re-plant.
    /// One ordered store: insertion order is the eviction order.
    private var redeemedCodes: OrderedDictionary<CodeHash, Date> = [:]
    /// M-07 per-table random salt for payload bindings. Fresh per init, so
    /// per daemon boot in production; bindings never verify across tables.
    private let payloadSalt: [UInt8]

    public init(epoch: UUID = UUID()) {
        self.epoch = epoch
        var generator = SystemRandomNumberGenerator()
        self.payloadSalt = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// Plants one grant. Empty views are refused. The expiry is clamped into
    /// `(now, now + maxTTL]` using the CALLER-provided clock reading `now`
    /// (the daemon passes its own clock; CLI attestations never set TTL).
    ///
    /// M-07: `maskedSegments` binds the grant to the exact hidden payload.
    /// Nil plants unbound (legacy); spend then fails closed on masked
    /// commands. Callers holding exact text must pass it (`[]` when
    /// nothing was masked). The TTY path binds via `payloadContentDigest`
    /// on the fingerprint entry instead.
    ///
    /// B1: `invocationPrefix` binds the erased invocation prefix (wrappers,
    /// assignments, argv0 path) by folding it into the fingerprint. Callers
    /// holding exact text must pass it (`[]` for a bare command).
    public func plant(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        codeHash: String,
        pendingID: String? = nil,
        now: Date,
        ttl: TimeInterval = EphemeralAllowOnceTable.maxTTL,
        maskedSegments: [String]? = nil,
        invocationPrefix: [String] = []
    ) -> PlantResult {
        guard matchingView.rawValue.isEmpty == false else { return .refused }
        let binding: PayloadBinding
        if let maskedSegments {
            binding = .salted(maskedPayloadSaltedDigest(maskedSegments, salt: payloadSalt))
        } else {
            binding = .unbound
        }
        return plantCore(
            fingerprint: grantFingerprint(matchingView, invocationPrefix: invocationPrefix),
            cwd: cwd,
            codeHash: CodeHash(rawValue: codeHash),
            pendingID: pendingID.map(ApprovalID.init(rawValue:)),
            now: now,
            ttl: ttl,
            binding: binding
        )
    }

    /// Fingerprint-plant for the TTY attestation path: the CLI knows the
    /// reviewed row's digest (bound pre-LA), never the full view. Same
    /// enforcement as the view entry; the daemon validates shape first.
    /// Refuses past `maxGrants` live grants (fail closed; the human
    /// retries against a pruned table).
    ///
    /// M-07: `payloadContentDigest` binds the grant to the reviewed row's
    /// payload digest (a digest only — exact segments never cross IPC).
    /// Nil plants unbound (legacy rows); spend then fails closed on
    /// masked commands. This entry takes no masked segments, so a
    /// both-bound plant does not compile.
    public func plant(
        fingerprint: GrantFingerprint,
        cwd: WorkingDirectory,
        codeHash: CodeHash,
        pendingID: ApprovalID? = nil,
        now: Date,
        ttl: TimeInterval = EphemeralAllowOnceTable.maxTTL,
        payloadContentDigest: ContentPayloadDigest? = nil
    ) -> PlantResult {
        let binding: PayloadBinding
        if let payloadContentDigest {
            binding = .content(payloadContentDigest)
        } else {
            binding = .unbound
        }
        return plantCore(
            fingerprint: fingerprint,
            cwd: cwd,
            codeHash: codeHash,
            pendingID: pendingID,
            now: now,
            ttl: ttl,
            binding: binding
        )
    }

    private func plantCore(
        fingerprint: GrantFingerprint,
        cwd: WorkingDirectory,
        codeHash: CodeHash,
        pendingID: ApprovalID?,
        now: Date,
        ttl: TimeInterval,
        binding: PayloadBinding
    ) -> PlantResult {
        guard fingerprint.rawValue.isEmpty == false else { return .refused }
        guard codeHash.rawValue.isEmpty == false else { return .refused }
        prune(now: now)
        guard redeemedCodes[codeHash] == nil else { return .alreadyRedeemed }
        guard grants.count < Self.maxGrants else { return .refused }
        let clampedTTL = min(max(ttl, 1), Self.maxTTL)
        let grant = Grant(
            fingerprint: fingerprint,
            cwd: cwd,
            codeHash: codeHash,
            pendingID: pendingID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(clampedTTL),
            binding: binding
        )
        redeemedCodes[codeHash] = now
        evictRedeemedCodesIfNeeded()
        grants[UUID()] = grant
        return .planted
    }

    /// Atomically spends one live grant for the exact (view, cwd,
    /// payload, invocation). Actor isolation makes concurrent consumers
    /// have exactly one winner.
    public func consume(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        now: Date,
        maskedSegments: [String]? = nil,
        invocationPrefix: [String] = []
    ) -> Bool {
        prune(now: now)
        let fingerprint = grantFingerprint(matchingView, invocationPrefix: invocationPrefix)
        guard let id = grants.first(where: { _, grant in
            grant.fingerprint == fingerprint && grant.cwd == cwd
                && payloadMatches(grant: grant, spend: maskedSegments)
        })?.key else {
            return false
        }
        grants.removeValue(forKey: id)
        return true
    }

    /// Non-spending presence check for peek/display paths.
    public func hasGrant(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        now: Date,
        maskedSegments: [String]? = nil,
        invocationPrefix: [String] = []
    ) -> Bool {
        prune(now: now)
        let fingerprint = grantFingerprint(matchingView, invocationPrefix: invocationPrefix)
        return grants.values.contains {
            $0.fingerprint == fingerprint && $0.cwd == cwd
                && payloadMatches(grant: $0, spend: maskedSegments)
        }
    }

    /// M-07 spend rule. Salted-bound grants require an equal salted
    /// digest; content-bound (TTY attested) grants require an equal
    /// content digest. Unbound (legacy) grants allow unknown/unmasked
    /// spends and fail closed when the spend hides a payload the grant
    /// cannot vouch for.
    private func payloadMatches(grant: Grant, spend: [String]?) -> Bool {
        switch grant.binding {
        case .salted(let binding):
            guard let spend else { return false }
            return maskedPayloadSaltedDigest(spend, salt: payloadSalt) == binding
        case .content(let content):
            guard let spend else { return false }
            return maskedPayloadContentDigest(spend) == content
        case .unbound:
            guard let spend else { return true }
            return spend.isEmpty
        }
    }

    private func prune(now: Date) {
        // Fail-closed boundary, harmonized: a grant live ⟺ expiresAt > now.
        grants = grants.filter { _, grant in grant.expiresAt > now }
    }

    /// FIFO eviction past `maxRedeemedCodes`. Codes are only ever
    /// removed here, from the front of the ordered store.
    private func evictRedeemedCodesIfNeeded() {
        while redeemedCodes.count > Self.maxRedeemedCodes, redeemedCodes.isEmpty == false {
            redeemedCodes.removeFirst()
        }
    }
}
