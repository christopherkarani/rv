import Foundation
import RVDomain

// MARK: - Host redemption wire (rvd → workspace host reverse RPC)
//
// After `rvd` atomically consumes a server-held `WorkspaceOperationPermit`,
// it commits the redemption to the exact live registered host over the
// already-authenticated service↔host bridge. The host verifies the commit
// against its own retained prepared state, atomically accepts at most once,
// and dispatches the retained launch — or refuses.
//
// The commit binds exact operation identity only. It carries no permit bytes
// (the server-held permit is the authority and is already consumed), no
// operator credential, no LocalAuthentication evidence, no RuntimeCapability,
// and no secret environment. DTOs are data only: the host accepts a commit
// only over the authenticated service channel and only when every binding
// matches its own retained prepared operation.

public enum HostRedeemWire {
    public static let redeemKey = "rv.host-redeem"
    public static let maxBodyBytes = 1_048_576
}

/// Authenticated permit-consumption assertion for exactly one prepared operation.
///
/// Correlation, not authority: the host re-verifies every binding against its
/// retained prepared state and its own (workspace, host, generation) identity
/// before accepting. A forged or replayed commit that fails any binding is
/// refused without dispatch.
public struct HostRedeemCommitDTO: Sendable, Equatable, Codable {
    /// Correlation-only authorization handle. Knowing it grants nothing.
    public let authorizationID: UUID
    public let workspaceSessionID: UUID
    public let hostID: UUID
    public let generation: UUID
    public let preparedID: UUID
    public let intentDigestHex: String
    /// "launchAgent" or "launchCustom".
    public let kind: String
    /// Named launches only; nil for custom.
    public let definitionID: String?
    /// Named launches only; nil for custom.
    public let revisionDigest: String?

    public init(
        authorizationID: UUID, workspaceSessionID: UUID, hostID: UUID, generation: UUID,
        preparedID: UUID, intentDigestHex: String, kind: String,
        definitionID: String?, revisionDigest: String?
    ) {
        self.authorizationID = authorizationID
        self.workspaceSessionID = workspaceSessionID
        self.hostID = hostID
        self.generation = generation
        self.preparedID = preparedID
        self.intentDigestHex = intentDigestHex
        self.kind = kind
        self.definitionID = definitionID
        self.revisionDigest = revisionDigest
    }
}

/// Host redemption outcome. Refusals are data, never throws.
///
/// - success: `accepted` with runtime/instance IDs (identifiers for audit
///   attribution only; never capabilities, never secrets).
/// - spent-but-failed: `accepted` with `error: "launchFailed"`. The
///   authorization is consumed and the prepared operation is spent; the
///   caller must not retry.
/// - in-flight duplicate: `accepted` with `error: "alreadyAccepted"`. Another
///   attempt holds the single acceptance; no second dispatch occurs.
/// - refused: `accepted == false` with `error: "unknown"`. Deliberately
///   undifferentiated (absent, expired, invalidated, binding mismatch,
///   workspace inactive, or cwd identity changed). No launch occurred and the
///   prepared operation is unspent by this refusal.
public struct HostRedeemResponseDTO: Sendable, Equatable, Codable {
    public let accepted: Bool
    public let runtimeSessionID: UUID?
    public let agentInstanceID: UUID?
    /// Machine-readable outcome when IDs are absent (see above).
    public let error: String?

    public init(
        accepted: Bool, runtimeSessionID: UUID? = nil, agentInstanceID: UUID? = nil,
        error: String? = nil
    ) {
        self.accepted = accepted
        self.runtimeSessionID = runtimeSessionID
        self.agentInstanceID = agentInstanceID
        self.error = error
    }
}

/// Verify + accept + dispatch exactly one prepared launch. Sync handler,
/// invoked off the host bridge's XPC event queue (redemption spawns must
/// not head-of-line-block the connection). Refusals and failures are data,
/// never throws. At most one call per prepared operation can accept.
public typealias HostRedeemHandler = @Sendable (HostRedeemCommitDTO) -> HostRedeemResponseDTO
