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
public actor EphemeralAllowOnceTable {
    public struct Grant: Sendable, Equatable {
        public var fingerprint: String
        public var cwd: WorkingDirectory
        public var codeHash: String
        public var pendingID: String?
        public var createdAt: Date
        public var expiresAt: Date

        public init(
            fingerprint: String,
            cwd: WorkingDirectory,
            codeHash: String,
            pendingID: String? = nil,
            createdAt: Date,
            expiresAt: Date
        ) {
            self.fingerprint = fingerprint
            self.cwd = cwd
            self.codeHash = codeHash
            self.pendingID = pendingID
            self.createdAt = createdAt
            self.expiresAt = expiresAt
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

    public init(epoch: UUID = UUID()) {
        self.epoch = epoch
    }

    /// Plants one grant. Empty views are refused. The expiry is clamped into
    /// `(now, now + maxTTL]` using the CALLER-provided clock reading `now`
    /// (the daemon passes its own clock; CLI attestations never set TTL).
    public func plant(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        codeHash: String,
        pendingID: String? = nil,
        now: Date,
        ttl: TimeInterval = EphemeralAllowOnceTable.maxTTL
    ) -> PlantResult {
        guard matchingView.rawValue.isEmpty == false else { return .refused }
        return plant(
            fingerprint: commandFingerprint(matchingView),
            cwd: cwd,
            codeHash: codeHash,
            pendingID: pendingID,
            now: now,
            ttl: ttl
        )
    }

    /// Fingerprint-plant for the TTY attestation path: the CLI knows the
    /// reviewed row's digest (bound pre-LA), never the full view. Same
    /// enforcement as the view entry; the daemon validates shape first.
    /// Refuses past `maxGrants` live grants (fail closed; the human
    /// retries against a pruned table).
    public func plant(
        fingerprint: String,
        cwd: WorkingDirectory,
        codeHash: String,
        pendingID: String? = nil,
        now: Date,
        ttl: TimeInterval = EphemeralAllowOnceTable.maxTTL
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
            expiresAt: now.addingTimeInterval(clampedTTL)
        )
        redeemedCodes[codeHash] = grant.expiresAt
        grants[UUID()] = grant
        return .planted
    }

    /// Atomically spends one live grant for the exact (view, cwd). Actor
    /// isolation makes concurrent consumers have exactly one winner.
    public func consume(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        now: Date
    ) -> Bool {
        prune(now: now)
        let fingerprint = commandFingerprint(matchingView)
        guard let id = grants.first(where: { _, grant in
            grant.fingerprint == fingerprint && grant.cwd == cwd
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
        now: Date
    ) -> Bool {
        prune(now: now)
        let fingerprint = commandFingerprint(matchingView)
        return grants.values.contains {
            $0.fingerprint == fingerprint && $0.cwd == cwd
        }
    }

    private func prune(now: Date) {
        grants = grants.filter { _, grant in grant.expiresAt >= now }
        redeemedCodes = redeemedCodes.filter { _, expiresAt in expiresAt >= now }
    }
}
