import Foundation
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
/// Binding per grant: exact canonical-action fingerprint + canonical cwd +
/// issuing epoch + strict expiry + atomic single-use. The issuing pending-approval
/// ID and ceremony code hash are recorded for audit and double-attest defense.
/// No continuation token is claimed: host protocols cannot establish one, so a
/// grant authorizes one re-issue of the exact action, nothing else.
///
/// M-07: the fingerprint covers the masked view only, so same-view commands
/// with different hidden payloads would share authority. Bound grants also
/// carry a payload digest of the exact masked segments; spend recomputes
/// and requires equality. Hook-ceremony plants bind `payloadBinding`, a
/// digest under a per-table random salt. TTY attestation plants bind
/// `payloadContentBinding`, the unsalted content digest the genuine CLI
/// reviewed (the daemon never sees exact text there, so no salted digest
/// is computable). Unbound grants (legacy rows without a digest) keep
/// legacy behavior for known-unmasked spends and fail closed on masked
/// spends. The salt and the segments never leave this actor.
public actor EphemeralAllowOnceTable {
    public struct Grant: Sendable, Equatable {
        public var fingerprint: String
        public var cwd: WorkingDirectory
        public var codeHash: String
        public var pendingID: String?
        public var createdAt: Date
        public var expiresAt: Date
        /// Salted masked-payload digest, or nil for unbound (legacy) plants.
        public var payloadBinding: String?
        /// Unsalted content digest from TTY attestation, when the reviewed
        /// row carried one. Mutually exclusive with `payloadBinding` in
        /// practice: hook plants set the salted form, attest plants the
        /// content form, legacy plants neither.
        public var payloadContentBinding: String?

        public init(
            fingerprint: String,
            cwd: WorkingDirectory,
            codeHash: String,
            pendingID: String? = nil,
            createdAt: Date,
            expiresAt: Date,
            payloadBinding: String? = nil,
            payloadContentBinding: String? = nil
        ) {
            self.fingerprint = fingerprint
            self.cwd = cwd
            self.codeHash = codeHash
            self.pendingID = pendingID
            self.createdAt = createdAt
            self.expiresAt = expiresAt
            self.payloadBinding = payloadBinding
            self.payloadContentBinding = payloadContentBinding
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

    private var grants: [UUID: Grant] = [:]
    /// Ceremony codes that already planted, with the expiry of the grant
    /// they planted. Pruned with the grants: without expiry the set grows
    /// forever on a same-user approval loop.
    private var redeemedCodes: [String: Date] = [:]
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
    public func plant(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        codeHash: String,
        pendingID: String? = nil,
        now: Date,
        ttl: TimeInterval = EphemeralAllowOnceTable.maxTTL,
        maskedSegments: [String]? = nil
    ) -> PlantResult {
        guard matchingView.rawValue.isEmpty == false else { return .refused }
        return plant(
            fingerprint: commandFingerprint(matchingView),
            cwd: cwd,
            codeHash: codeHash,
            pendingID: pendingID,
            now: now,
            ttl: ttl,
            maskedSegments: maskedSegments
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
    /// masked commands.
    public func plant(
        fingerprint: String,
        cwd: WorkingDirectory,
        codeHash: String,
        pendingID: String? = nil,
        now: Date,
        ttl: TimeInterval = EphemeralAllowOnceTable.maxTTL,
        maskedSegments: [String]? = nil,
        payloadContentDigest: String? = nil
    ) -> PlantResult {
        guard fingerprint.isEmpty == false else { return .refused }
        guard codeHash.isEmpty == false else { return .refused }
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
            payloadBinding: maskedSegments.map { maskedPayloadSaltedDigest($0, salt: payloadSalt) },
            payloadContentBinding: payloadContentDigest
        )
        redeemedCodes[codeHash] = grant.expiresAt
        grants[UUID()] = grant
        return .planted
    }

    /// Atomically spends one live grant for the exact (view, cwd, payload).
    /// Actor isolation makes concurrent consumers have exactly one winner.
    public func consume(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        now: Date,
        maskedSegments: [String]? = nil
    ) -> Bool {
        prune(now: now)
        let fingerprint = commandFingerprint(matchingView)
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
        maskedSegments: [String]? = nil
    ) -> Bool {
        prune(now: now)
        let fingerprint = commandFingerprint(matchingView)
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
        if let binding = grant.payloadBinding {
            guard let spend else { return false }
            return maskedPayloadSaltedDigest(spend, salt: payloadSalt) == binding
        }
        if let content = grant.payloadContentBinding {
            guard let spend else { return false }
            return maskedPayloadContentDigest(spend) == content
        }
        guard let spend else { return true }
        return spend.isEmpty
    }

    private func prune(now: Date) {
        grants = grants.filter { _, grant in grant.expiresAt >= now }
        redeemedCodes = redeemedCodes.filter { _, expiresAt in expiresAt >= now }
    }
}
