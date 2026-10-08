import Foundation
import RVDomain
import RVIsolation

// MARK: - Step 6: principal-bound action approvals (state model)
//
// `rvd` records authority for one exact action, one exact live AgentInstance,
// one exact authenticated continuation, for a bounded lifetime, and that
// authority is consumed at most once. This file holds the state model;
// `ActionApprovalAuthorizer` (actor) owns every transition.
//
// Nothing here is authority by possession: approval IDs, challenge IDs,
// continuation IDs, references and digests are lookup/correlation only. The
// authorizer's memory is the authority. No type in this file is Codable,
// and none may gain a wire initializer. The host and UI bridges carry
// descriptive DTOs (see `ActionApprovalWire`); the authorizer re-validates
// every decisive call against its retained records, the authenticated peer,
// and live principal validity.
//
// This state machine is deliberately separate from the Step 3 launch
// authorizer: a `WorkspaceOperationPermit` authorizes an identity launch,
// an `ActionApprovalGrant` authorizes one exact action of an already-running
// agent. They share infrastructure patterns (issuer epoch, monotonic
// deadlines, consume-once discipline, trusted UI channel) but never
// authority records: no reference, challenge, or grant of one machine is
// accepted by the other.

// MARK: - Issuer epoch

/// Fresh unguessable identity of one action-approval subsystem lifetime.
///
/// Minted once in `ActionApprovalAuthorizer.init` and never persisted, so a
/// service restart inherently invalidates every approval/challenge/grant from
/// the prior epoch. Knowledge of an epoch grants nothing; it only lets a new
/// incarnation recognize (and reject) stale references.
struct ActionApprovalIssuerEpoch: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    /// Names an epoch for comparison only (tests, stale-reference rejection).
    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Service-minted identifiers

/// Service-owned record ID for one pending action approval.
///
/// Minted by the authorizer at creation. Correlation only: knowing an ID
/// grants nothing, and no caller selects the authority-bearing record ID.
struct ActionApprovalID: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Service-minted ID for one operator authentication challenge.
struct ActionApprovalChallengeID: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Service-minted ID for the one exact continuation an approval resumes.
///
/// Minted by the authorizer at creation alongside the approval ID. The host
/// holds its parked continuation in memory and presents this ID (over the
/// authenticated host bridge, with the live-validated principal and the
/// exact action digest) to consume the grant. Correlation only: knowledge
/// of a continuation ID grants nothing without the authenticated live
/// principal, the exact action, and an unconsumed unexpired grant.
struct ActionApprovalContinuationID: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Principal binding

/// Exact live principal one approval is bound to.
///
/// Service-derived from a freshly validated `ServiceValidatedAgentContext`
/// plus the trusted `AgentInstance` record the host's validity RPC
/// attested. Never decoded from request bytes: the creation path takes the
/// validated reference (whose every field the registry just proved live)
/// and the instance's definition/owner facts from the same trusted source.
/// A name, PID, session label, or workspace path alone is never enough.
struct ActionApprovalPrincipal: Sendable, Equatable {
    let instanceID: AgentInstanceID
    let definitionID: AgentDefinitionID
    let definitionRevision: AgentDefinitionRevision
    let runtimeSessionID: RuntimeSessionID
    let workspaceSessionID: WorkspaceSessionID
    let hostID: WorkspaceHostID
    let hostGeneration: WorkspaceHostGeneration
    let owner: OwnerPrincipal
}

// MARK: - Pending approval

/// One exact action of one exact live principal awaiting human authorization.
///
/// Compact bindings only — the pattern Step 3 established (intent digest in
/// the authorizer, full description in the ceremony). The full action, the
/// policy reason, and the policy context live only in the ceremony's
/// retained review (needed for trusted UI display) and are dropped the
/// moment the approval turns terminal.
struct PendingActionApproval: Sendable, Equatable {
    let id: ActionApprovalID
    let epoch: ActionApprovalIssuerEpoch
    let principal: ActionApprovalPrincipal
    /// Authenticated host channel that requested the approval. Disconnect
    /// invalidates every live record bound to it.
    let hostConnectionID: UUID
    /// `CanonicalActionDigest` of the bound action, computed by the service
    /// at creation. Compared at completion and consumption; never trusted
    /// from any presenter until it matches this retained value.
    let actionDigestHex: String
    /// The one continuation this approval may resume.
    let continuationID: ActionApprovalContinuationID
    /// Audit only; security expiry is `deadlineMono`.
    let createdWall: Date
    /// Parent approval deadline. Bounds every challenge and grant.
    let deadlineMono: ContinuousClock.Instant
    var state: ActionApprovalState
}

/// Closed lifecycle. Terminal states never leave terminal state; there is no
/// transition out of `consumed`, `denied`, `cancelled`, `expired`,
/// `invalidated` or `failed`.
enum ActionApprovalState: Sendable, Equatable {
    case pendingReview
    case challengeIssued(ActionApprovalChallenge)
    case authorized(ActionApprovalGrant)
    case consumed
    case denied
    case cancelled
    case expired
    case invalidated
    case failed
}

// MARK: - Challenge

/// One exact pending approval offered for authentication. Not authority:
/// possession of a challenge grants nothing, and a challenge never equals
/// a grant. Completion must arrive over the same authenticated UI context
/// and re-prove the principal live before any grant issues.
struct ActionApprovalChallenge: Sendable, Equatable {
    let id: ActionApprovalChallengeID
    let epoch: ActionApprovalIssuerEpoch
    let approvalID: ActionApprovalID
    let principal: ActionApprovalPrincipal
    let actionDigestHex: String
    let continuationID: ActionApprovalContinuationID
    /// Completion must arrive over this same authenticated UI context.
    let uiConnection: AuthenticatedOperatorUIConnectionID
    /// Audit only.
    let issuedWall: Date
    /// `min(issued + challengeLifetime, parent approval deadline)`.
    let deadlineMono: ContinuousClock.Instant
}

// MARK: - Grant

/// Internal `rvd` record of one granted action authorization. Server-held,
/// ephemeral, consume-once. Not Codable, not a Bearer [REDACTED] carries no
/// capability and no secrets. The authorizer's memory is the authority;
/// this struct is its shape.
///
/// Knowing a grant exists (or naming its approval/continuation IDs) is not
/// sufficient to consume it. Consumption additionally requires the
/// authenticated live principal, the exact action digest, the exact
/// continuation, and an unexpired unconsumed grant.
struct ActionApprovalGrant: Sendable, Equatable {
    let approvalID: ActionApprovalID
    let epoch: ActionApprovalIssuerEpoch
    let actor: OperatorAuthorizationActor
    let principal: ActionApprovalPrincipal
    let hostConnectionID: UUID
    let actionDigestHex: String
    let continuationID: ActionApprovalContinuationID
    let challengeID: ActionApprovalChallengeID
    let uiConnection: AuthenticatedOperatorUIConnectionID
    /// Audit only.
    let issuedWall: Date
    /// `min(issued + grantLifetime, parent approval deadline)`.
    let expiryMono: ContinuousClock.Instant
}

// MARK: - Opaque reference and consumption result

/// Opaque handle for grant consumption. Lookup/correlation only: knowing a
/// reference is not authority. Consumption additionally requires the
/// authenticated live principal, exact action digest, exact continuation,
/// and an unexpired, unconsumed grant.
struct ActionApprovalReference: Hashable, Sendable, Equatable {
    let approvalID: ActionApprovalID
    let epoch: ActionApprovalIssuerEpoch
}

/// Exact expected bindings a consumer must present. Every field is compared
/// against the server-held grant; any mismatch fails closed.
struct ActionApprovalConsumeExpectation: Sendable, Equatable {
    let principal: ActionApprovalPrincipal
    let actionDigestHex: String
    let continuationID: ActionApprovalContinuationID
}

/// Trusted service-internal result of one atomic consumption, shaped for the
/// host resume path. Data only: no execution here. Only
/// `ActionApprovalAuthorizer.consumeGrant` may mint one, inside the
/// validated state transition; authenticated service state — not Swift
/// access control — is the trust root.
struct VerifiedActionApprovalConsumption: Sendable, Equatable {
    let approvalID: ActionApprovalID
    let epoch: ActionApprovalIssuerEpoch
    let actor: OperatorAuthorizationActor
    let principal: ActionApprovalPrincipal
    let actionDigestHex: String
    let continuationID: ActionApprovalContinuationID
    let challengeID: ActionApprovalChallengeID
    let uiConnection: AuthenticatedOperatorUIConnectionID
    let consumedWall: Date
    let consumedMono: ContinuousClock.Instant
}

// MARK: - Status (read-only, grants nothing)

enum ActionApprovalStatus: Sendable, Equatable {
    case pending
    case awaitingAuthentication
    case authorized
    case consumed
    case denied
    case cancelled
    case expired
    case invalidated
    case failed
}

// MARK: - Limits (centralized; no scattered literals)

enum ActionApprovalLimits {
    static let maxApprovals = 64
    /// One principal may hold at most this many live approvals. Without a
    /// per-principal bound, one hostile agent could fill the 64-slot store
    /// and deny the approval path to every other agent (availability).
    /// Terminal records never count: only live authority is bounded.
    static let maxLivePerPrincipal = 8
    /// A pending approval must survive human review latency.
    static let approvalLifetime: TimeInterval = 15 * 60
    /// A bound review must survive an explicit review plus one LA ceremony.
    static let challengeLifetime: TimeInterval = 5 * 60
    /// A grant must be consumed promptly by the waiting host continuation.
    static let grantLifetime: TimeInterval = 60
}

// MARK: - Errors

enum ActionApprovalError: Error, Sendable, Equatable {
    /// No record (never existed, or swept after its bounded lifetime).
    case unknownApproval
    /// Presented epoch differs from this authorizer's issuer epoch.
    case wrongEpoch
    /// Current state admits no such transition.
    case stateMismatch
    /// At least one exact binding differs. Which one is not disclosed.
    case bindingMismatch
    /// Past the monotonic deadline (`now == expiry` fails closed).
    case expired
    /// Already consumed. Replay, including concurrent replay.
    case consumed
    /// Store full after evicting every parent-expired record.
    case storeFull
    /// Creation-time validation failed.
    case invalidRequest
    /// Valid completion whose authentication result was not success. The
    /// approval is terminally `failed`; no grant exists.
    case authenticationFailed
    /// The bound principal is no longer live. The approval is terminally
    /// `invalidated`; no grant exists or survives.
    case principalInvalid
}

// MARK: - Audit events (sink wiring deferred; event type ready)

/// Structured audit event. Carries identities, digests and outcomes only —
/// never passwords, biometric data, secret environment, capabilities, raw
/// commands, or raw action arguments. The action digest is descriptive;
/// possessing it grants nothing.
struct ActionApprovalAuditEvent: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case approvalCreated
        case challengeIssued
        case authenticationCompleted
        case grantIssued
        case grantConsumed
        case approvalDenied
        case approvalCancelled
        case approvalExpired
        case approvalFailed
        case approvalInvalidated
        case grantInvalidated
        case replayRejected
    }

    let kind: Kind
    let approvalID: ActionApprovalID
    let principal: ActionApprovalPrincipal
    let actionDigestHex: String
    let continuationID: ActionApprovalContinuationID
    let actor: OperatorAuthorizationActor?
    /// Wall-clock capture for audit ordering only; never drives expiry.
    let wall: Date
    let outcome: String
}
