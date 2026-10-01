import Foundation
import RVDomain
import RVIsolation

// MARK: - Step 3: service-owned challenge/permit state (no UI, no redemption)
//
// `rvd` records authority for one exact prepared operation, one exact host
// incarnation, one exact authenticated ceremony, for a bounded lifetime, and
// that authority is consumed at most once. This file holds the state model;
// `WorkspaceOperatorAuthorizer` (actor) owns every transition.
//
// Nothing here is authority by possession: challenges, references and digests
// are lookup/correlation only. The authorizer's memory is the authority.
// No type in this file is Codable, and none may gain a wire initializer.

// MARK: - Issuer epoch

/// Fresh unguessable identity of one service authorization subsystem lifetime.
///
/// Minted once in `WorkspaceOperatorAuthorizer.init` and never persisted, so a
/// service restart inherently invalidates every challenge/permit from the prior
/// epoch. Knowledge of an epoch grants nothing; it only lets a new incarnation
/// recognize (and reject) stale references.
struct WorkspaceAuthorizationIssuerEpoch: Hashable, Sendable, Equatable {
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

/// Service-owned record ID for one pending workspace-operation authorization.
///
/// Minted by the authorizer at creation. Never a client request ID, never a
/// `PreparedLaunchID`, never an intent digest: no caller selects the
/// authority-bearing record ID.
struct WorkspaceOperationAuthorizationID: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Service-minted ID for one operator authentication challenge.
struct OperatorAuthorizationChallengeID: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Transport-established identity of one authenticated operator-UI connection.
///
/// Placeholder binding until the trusted Step 4 UI transport exists. This is
/// descriptive context only: never a PID, bundle ID, or UID, none of which
/// constitute operator authority.
struct AuthenticatedOperatorUIConnectionID: Hashable, Sendable, Equatable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Operation kind

/// The only operations this state machine authorizes: identity launches.
enum WorkspaceOperationKind: Sendable, Equatable {
    case launchAgent
    case launchCustom
}

// MARK: - Descriptive bindings (service-derived, never wire-decoded)

/// Snapshot of the authenticated requesting context, for lifecycle binding and audit.
struct WorkspaceAuthorizationRequester: Sendable, Equatable {
    let connectionID: UUID
    let componentRole: TrustedRVComponentRole?

    init(context: AuthenticatedRequestContext) {
        self.connectionID = context.connectionID
        self.componentRole = context.componentRole
    }

    /// Trusted internal fixture (tests, future service paths). No wire path
    /// may construct requester identity from client fields.
    init(connectionID: UUID, componentRole: TrustedRVComponentRole?) {
        self.connectionID = connectionID
        self.componentRole = componentRole
    }
}

/// Exact live host incarnation this authorization is bound to.
struct WorkspaceHostRegistrationBinding: Sendable, Equatable {
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    /// Authenticated registration/connection identity of the live host channel.
    let connectionID: UUID
}

/// Indexed/audit definition metadata. The real semantic binding is always the
/// exact prepared launch plus intent digest, never name/revision alone.
struct WorkspaceOperationDefinitionBinding: Sendable, Equatable {
    let definitionID: AgentDefinitionID
    let revision: AgentDefinitionRevision
}

// MARK: - Authentication result and actor

/// Narrow trusted completion of one challenge. Constructed only by trusted
/// service/UI integration (Step 4); there is deliberately no Codable
/// conformance and no IPC payload that can assert `.authenticated`.
enum OperatorAuthenticationResult: Sendable, Equatable {
    case authenticated
    case cancelled
    case unavailable
    case failed
}

enum OperatorAuthenticationMechanism: String, Sendable, Equatable {
    /// Fresh device-owner authentication; no specific biometric modality claimed.
    case deviceOwnerAuthentication
}

/// Descriptive provenance attached to trusted issuance, for audit only.
struct OperatorAuthorizationActor: Sendable, Equatable {
    let mechanism: OperatorAuthenticationMechanism
    let uiConnection: AuthenticatedOperatorUIConnectionID
}

// MARK: - Pending operation

/// One exact host-prepared launch awaiting future human authorization.
struct PendingWorkspaceOperation: Sendable, Equatable {
    let id: WorkspaceOperationAuthorizationID
    let epoch: WorkspaceAuthorizationIssuerEpoch
    let requester: WorkspaceAuthorizationRequester
    /// Correlation only. Never a record key, never compared at consume time.
    let clientRequestID: UUID?
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let registration: WorkspaceHostRegistrationBinding
    let preparedLaunch: PreparedLaunchID
    let intentDigest: WorkspaceLaunchIntentDigest
    let kind: WorkspaceOperationKind
    /// Required for `.launchAgent`, forbidden for `.launchCustom`.
    let definition: WorkspaceOperationDefinitionBinding?
    /// Audit only; security expiry is `deadlineMono`.
    let createdWall: Date
    /// Parent operation deadline. Bounds every challenge and permit.
    let deadlineMono: ContinuousClock.Instant
    var state: WorkspaceOperationAuthorizationState
}

/// Closed lifecycle. Terminal states never leave terminal state; there is no
/// transition out of `consumed`, `cancelled`, `expired`, `invalidated` or `failed`.
enum WorkspaceOperationAuthorizationState: Sendable, Equatable {
    case pendingReview
    case challengeIssued(OperatorAuthorizationChallenge)
    case authorized(WorkspaceOperationPermit)
    case consumed
    case cancelled
    case expired
    case invalidated
    case failed
}

// MARK: - Challenge

/// One exact pending operation offered for authentication. Not authority:
/// possession of a challenge grants nothing, and a challenge never equals a permit.
struct OperatorAuthorizationChallenge: Sendable, Equatable {
    let id: OperatorAuthorizationChallengeID
    let epoch: WorkspaceAuthorizationIssuerEpoch
    let operationID: WorkspaceOperationAuthorizationID
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let registration: WorkspaceHostRegistrationBinding
    let preparedLaunch: PreparedLaunchID
    let intentDigest: WorkspaceLaunchIntentDigest
    let kind: WorkspaceOperationKind
    /// Completion must arrive over this same authenticated UI context.
    let uiConnection: AuthenticatedOperatorUIConnectionID
    /// Audit only.
    let issuedWall: Date
    /// `min(issued + challengeLifetime, parent operation deadline)`.
    let deadlineMono: ContinuousClock.Instant
}

// MARK: - Permit

/// Internal `rvd` record of one granted authorization. Server-held, ephemeral,
/// consume-once. Not Codable, not a bearer token, carries no capability and no
/// secrets. The authorizer's memory is the authority; this struct is its shape.
struct WorkspaceOperationPermit: Sendable, Equatable {
    let authorizationID: WorkspaceOperationAuthorizationID
    let epoch: WorkspaceAuthorizationIssuerEpoch
    let actor: OperatorAuthorizationActor
    let requester: WorkspaceAuthorizationRequester
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let registration: WorkspaceHostRegistrationBinding
    let preparedLaunch: PreparedLaunchID
    let kind: WorkspaceOperationKind
    let intentDigest: WorkspaceLaunchIntentDigest
    let definition: WorkspaceOperationDefinitionBinding?
    let challengeID: OperatorAuthorizationChallengeID
    let uiConnection: AuthenticatedOperatorUIConnectionID
    /// Audit only.
    let issuedWall: Date
    /// `min(issued + permitLifetime, parent operation deadline)`.
    let expiryMono: ContinuousClock.Instant
}

// MARK: - Opaque reference and redemption result

/// Opaque handle for future host protocol use. Lookup/correlation only:
/// knowing a reference is not authority. Redemption additionally requires the
/// authenticated registered host, exact workspace/generation/prepared/digest
/// bindings, and an unexpired, unconsumed permit. No redemption exists yet.
struct WorkspaceOperationAuthorizationReference: Hashable, Sendable, Equatable {
    let authorizationID: WorkspaceOperationAuthorizationID
    let epoch: WorkspaceAuthorizationIssuerEpoch
}

/// Exact expected bindings a future consumer must present to redeem.
struct WorkspaceOperationRedemptionExpectation: Sendable, Equatable {
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let registration: WorkspaceHostRegistrationBinding
    let preparedLaunch: PreparedLaunchID
    let intentDigest: WorkspaceLaunchIntentDigest
    let kind: WorkspaceOperationKind
}

/// Trusted service-internal result of one atomic consumption, shaped for future
/// host integration. Data only: no supervisor calls, no spawn, no instance,
/// no capability. Only `WorkspaceOperatorAuthorizer.consumePermit` may mint
/// one, inside the validated state transition; authenticated service state —
/// not Swift access control — is the trust root.
struct VerifiedWorkspaceOperationRedemption: Sendable, Equatable {
    let authorizationID: WorkspaceOperationAuthorizationID
    let epoch: WorkspaceAuthorizationIssuerEpoch
    let actor: OperatorAuthorizationActor
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let registration: WorkspaceHostRegistrationBinding
    let preparedLaunch: PreparedLaunchID
    let kind: WorkspaceOperationKind
    let intentDigest: WorkspaceLaunchIntentDigest
    let definition: WorkspaceOperationDefinitionBinding?
    let challengeID: OperatorAuthorizationChallengeID
    let uiConnection: AuthenticatedOperatorUIConnectionID
    let consumedWall: Date
    let consumedMono: ContinuousClock.Instant
}

// MARK: - Status (read-only, grants nothing)

enum WorkspaceOperationAuthorizationStatus: Sendable, Equatable {
    case pending
    case awaitingAuthentication
    case authorized
    case consumed
    case cancelled
    case expired
    case invalidated
    case failed
}

// MARK: - Limits (centralized; no scattered literals)

enum WorkspaceOperatorAuthorizationLimits {
    static let maxOperations = 64
    static let operationLifetime: TimeInterval = 120
    static let challengeLifetime: TimeInterval = 60
    static let permitLifetime: TimeInterval = 30
}

// MARK: - Errors

enum WorkspaceOperatorAuthorizationError: Error, Sendable, Equatable {
    /// No record (never existed, or swept after its bounded lifetime).
    case unknownOperation
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
    /// Creation-time validation failed (kind/definition or binding consistency).
    case invalidRequest
    /// Valid completion whose authentication result was not success. The
    /// operation is terminally `failed`; no permit exists.
    case authenticationFailed
}

// MARK: - Audit events (sink wiring deferred; event type ready)

/// Structured audit event. Carries identities, digests and outcomes only —
/// never passwords, biometric data, secret environment, capabilities, or argv.
struct WorkspaceOperatorAuthorizationAuditEvent: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case operationCreated
        case challengeIssued
        case authenticationCompleted
        case permitIssued
        case permitInvalidated
        case operationInvalidated
        case operationCancelled
        case operationExpired
        case operationFailed
        case permitConsumed
        case replayRejected
    }

    let kind: Kind
    let operationID: WorkspaceOperationAuthorizationID
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let preparedLaunch: PreparedLaunchID
    let intentDigestHex: String
    let operationKind: WorkspaceOperationKind
    let actor: OperatorAuthorizationActor?
    /// Wall-clock capture for audit ordering only; never drives expiry.
    let wall: Date
    let outcome: String
}
