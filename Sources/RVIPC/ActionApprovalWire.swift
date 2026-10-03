import Foundation
import RVDomain

// MARK: - Action-approval wire (Step 6)
//
// Two channels, both descriptive-DTOs-only. Nothing here is authority: the
// service re-validates every decisive call against its retained authorizer
// records, the authenticated peer, the bound UI connection, and live
// principal validity. Decoded data alone never creates trust.
//
// These types are deliberately distinct from the launch-authorization DTOs
// in `WorkspaceOperatorWire`. Launch review and action review are different
// UI modes with different state types; no generic optional-field DTO spans
// both, so a completion for one can never be mistaken for the other.

// MARK: - Host bridge RPC (rvd ↔ workspace host)

// XPC dictionary keys for action-approval RPCs. Results ride the standard
// `rv.ipc` IPCResponse envelope, mirroring the host bridge.
public enum HostActionApprovalWire {
    public static let createKey = "rv.host-action-approval-create"
    public static let statusKey = "rv.host-action-approval-status"
    public static let consumeKey = "rv.host-action-approval-consume"
    public static let cancelKey = "rv.host-action-approval-cancel"

    public static let maxBodyBytes = 1_048_576
}

/// Host request to record one ASK as a principal-bound approval.
///
/// The host normalized `action` itself and evaluated its own policy to ASK;
/// the service re-proves the principal live, binds the exact action, and
/// mints the approval + continuation IDs. `reason` is a closed vocabulary
/// (`mandatoryHuman`, `reviewAsk`); anything else fails closed.
///
/// `definitionID` / `definitionRevision` are host-attested descriptions:
/// definitions live host-side (as with named launch intents), so the
/// service binds them as reported while instance discrimination — the
/// security property — comes from the live-validated instance ID. The
/// owner is never taken from these bytes: the service derives it from the
/// authenticated peer.
public struct HostActionApprovalCreateDTO: Sendable, Equatable, Codable {
    public let reference: AgentPrincipalReference
    public let action: ProposedAction
    public let reason: String
    public let policyContext: String
    public let definitionID: AgentDefinitionID
    public let definitionRevision: AgentDefinitionRevision

    public init(
        reference: AgentPrincipalReference,
        action: ProposedAction,
        reason: String,
        policyContext: String,
        definitionID: AgentDefinitionID,
        definitionRevision: AgentDefinitionRevision
    ) {
        self.reference = reference
        self.action = action
        self.reason = reason
        self.policyContext = policyContext
        self.definitionID = definitionID
        self.definitionRevision = definitionRevision
    }
}

/// Service answer to a create request. IDs are correlation only.
public struct HostActionApprovalCreatedDTO: Sendable, Equatable, Codable {
    public let approvalID: UUID
    public let continuationID: UUID
    public let status: String

    public init(approvalID: UUID, continuationID: UUID, status: String) {
        self.approvalID = approvalID
        self.continuationID = continuationID
        self.status = status
    }
}

/// Host poll for a safe status string. Never consumes, never a grant.
public struct HostActionApprovalStatusDTO: Sendable, Equatable, Codable {
    public let approvalID: UUID
    public let reference: AgentPrincipalReference

    public init(approvalID: UUID, reference: AgentPrincipalReference) {
        self.approvalID = approvalID
        self.reference = reference
    }
}

/// Safe status projection. Never a grant, never authority.
public struct HostActionApprovalStatusReplyDTO: Sendable, Equatable, Codable {
    public let status: String

    public init(status: String) {
        self.status = status
    }
}

/// Host request to consume one grant for its parked continuation.
///
/// Presents the exact principal reference, the exact action digest, and the
/// exact continuation ID. The service re-proves the principal live and
/// atomically consumes at most once.
public struct HostActionApprovalConsumeDTO: Sendable, Equatable, Codable {
    public let approvalID: UUID
    public let reference: AgentPrincipalReference
    public let actionDigestHex: String
    public let continuationID: UUID

    public init(
        approvalID: UUID,
        reference: AgentPrincipalReference,
        actionDigestHex: String,
        continuationID: UUID
    ) {
        self.approvalID = approvalID
        self.reference = reference
        self.actionDigestHex = actionDigestHex
        self.continuationID = continuationID
    }
}

/// Service answer to a consume request.
///
/// `mayExecute` is true if and only if THIS call atomically consumed the
/// grant for the exact presented bindings. Any other answer means do not
/// run — including `mayExecute == false` on replay, on mismatch, or once
/// the ceremony has forgotten the terminal approval (`status == "unknown"`).
/// The status string is informational; the bit is the decision.
public struct HostActionApprovalDecisionDTO: Sendable, Equatable, Codable {
    public let status: String
    public let mayExecute: Bool

    public init(status: String, mayExecute: Bool) {
        self.status = status
        self.mayExecute = mayExecute
    }
}

/// Host request to cancel one approval (its parked continuation went away).
public struct HostActionApprovalCancelDTO: Sendable, Equatable, Codable {
    public let approvalID: UUID
    public let reference: AgentPrincipalReference

    public init(approvalID: UUID, reference: AgentPrincipalReference) {
        self.approvalID = approvalID
        self.reference = reference
    }
}

// MARK: - Operator UI bridge (rvd ↔ RVOperatorUI, action mode)

// Narrow UI service API for action approvals. No generic mutation endpoint.
public enum UIActionBridgeRequest: Sendable, Equatable {
    case actionList
    case actionBind(approvalID: UUID)
    case actionComplete(UIActionCompletion)
    case actionDeny(UIActionDeny)
    case actionCancel(approvalID: UUID)
    case actionStatus(approvalID: UUID)
}

extension UIActionBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case actionList
        case actionBind
        case actionComplete
        case actionDeny
        case actionCancel
        case actionStatus
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .actionList:
            try container.encode(EmptyPayload(), forKey: .actionList)
        case .actionBind(let approvalID):
            try container.encode(approvalID, forKey: .actionBind)
        case .actionComplete(let completion):
            try container.encode(completion, forKey: .actionComplete)
        case .actionDeny(let deny):
            try container.encode(deny, forKey: .actionDeny)
        case .actionCancel(let approvalID):
            try container.encode(approvalID, forKey: .actionCancel)
        case .actionStatus(let approvalID):
            try container.encode(approvalID, forKey: .actionStatus)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.actionList) {
            self = .actionList
        } else if let approvalID = try container.decodeIfPresent(UUID.self, forKey: .actionBind) {
            self = .actionBind(approvalID: approvalID)
        } else if let completion = try container.decodeIfPresent(
            UIActionCompletion.self, forKey: .actionComplete)
        {
            self = .actionComplete(completion)
        } else if let deny = try container.decodeIfPresent(UIActionDeny.self, forKey: .actionDeny) {
            self = .actionDeny(deny)
        } else if let approvalID = try container.decodeIfPresent(UUID.self, forKey: .actionCancel) {
            self = .actionCancel(approvalID: approvalID)
        } else if let approvalID = try container.decodeIfPresent(UUID.self, forKey: .actionStatus) {
            self = .actionStatus(approvalID: approvalID)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown UIActionBridgeRequest")
            )
        }
    }
}

/// Explicit allow-once completion. The UI reports its fresh
/// device-owner-authentication outcome; descriptive only until the service
/// validates peer, connection, challenge, epoch, bindings, and liveness.
public struct UIActionCompletion: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let approvalID: UUID
    public let outcome: UIAuthenticationOutcome

    public init(challengeID: UUID, approvalID: UUID, outcome: UIAuthenticationOutcome) {
        self.challengeID = challengeID
        self.approvalID = approvalID
        self.outcome = outcome
    }
}

/// Explicit deny for the exact bound review. No authentication: deny grants
/// nothing. Still bound to the live challenge so one connection cannot deny
/// another connection's review.
public struct UIActionDeny: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let approvalID: UUID

    public init(challengeID: UUID, approvalID: UUID) {
        self.challengeID = challengeID
        self.approvalID = approvalID
    }
}

/// Service-issued action-review challenge projection, retained verbatim by
/// the UI from review through completion. Advisory timing only; service
/// monotonic state decides.
public struct UIActionChallengeDTO: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let approvalID: UUID
    public let actionDigestHex: String
    public let uiConnectionID: UUID
    public let issuedWall: Date
    public let advisoryLifetimeSeconds: Double

    public init(
        challengeID: UUID, approvalID: UUID, actionDigestHex: String,
        uiConnectionID: UUID, issuedWall: Date, advisoryLifetimeSeconds: Double
    ) {
        self.challengeID = challengeID
        self.approvalID = approvalID
        self.actionDigestHex = actionDigestHex
        self.uiConnectionID = uiConnectionID
        self.issuedWall = issuedWall
        self.advisoryLifetimeSeconds = advisoryLifetimeSeconds
    }
}

/// One reviewable pending action approval, projected for trusted display.
///
/// All fields derive from the service's retained record (principal binding
/// plus the exact bound action); agent-provided explanatory text never
/// replaces these trusted labels. Secret-shaped action parameters are
/// redacted for display; the authorization itself binds the unredacted
/// digest, shown here so the exact authority is inspectable.
public struct UIActionReviewItemDTO: Sendable, Equatable, Codable {
    public let approvalID: UUID
    public let instanceID: UUID
    public let definitionID: String
    public let definitionRevisionDigest: String
    public let runtimeSessionID: UUID
    public let workspaceSessionID: UUID
    public let hostID: UUID
    public let actionKind: String
    public let exactTarget: String
    public let exactArguments: String
    public let policyReason: String
    public let scopeSummary: String
    public let actionDigestHex: String
    public let status: String
    public let advisoryExpiresWall: Date?

    public init(
        approvalID: UUID, instanceID: UUID, definitionID: String,
        definitionRevisionDigest: String, runtimeSessionID: UUID, workspaceSessionID: UUID,
        hostID: UUID, actionKind: String, exactTarget: String, exactArguments: String,
        policyReason: String, scopeSummary: String, actionDigestHex: String,
        status: String, advisoryExpiresWall: Date?
    ) {
        self.approvalID = approvalID
        self.instanceID = instanceID
        self.definitionID = definitionID
        self.definitionRevisionDigest = definitionRevisionDigest
        self.runtimeSessionID = runtimeSessionID
        self.workspaceSessionID = workspaceSessionID
        self.hostID = hostID
        self.actionKind = actionKind
        self.exactTarget = exactTarget
        self.exactArguments = exactArguments
        self.policyReason = policyReason
        self.scopeSummary = scopeSummary
        self.actionDigestHex = actionDigestHex
        self.status = status
        self.advisoryExpiresWall = advisoryExpiresWall
    }
}

public struct UIActionReviewListDTO: Sendable, Equatable, Codable {
    public let items: [UIActionReviewItemDTO]

    public init(items: [UIActionReviewItemDTO]) {
        self.items = items
    }
}

/// Bound action review: the retained challenge plus the item under review.
public struct UIActionChallengeBundleDTO: Sendable, Equatable, Codable {
    public let challenge: UIActionChallengeDTO
    public let item: UIActionReviewItemDTO

    public init(challenge: UIActionChallengeDTO, item: UIActionReviewItemDTO) {
        self.challenge = challenge
        self.item = item
    }
}

/// Safe action-approval status projection. Never grant contents, never a
/// reference.
public struct UIActionStatusDTO: Sendable, Equatable, Codable {
    public let approvalID: UUID
    public let status: String

    public init(approvalID: UUID, status: String) {
        self.approvalID = approvalID
        self.status = status
    }
}
