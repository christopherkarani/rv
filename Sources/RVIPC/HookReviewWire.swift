import Foundation
import RVDomain

// MARK: - Hook-review wire (Step 8B)
//
// Operator-UI review for legacy hook asks (pending hook waits), mirroring
// the Step 6 action-review vocabulary with a separate request enum, separate
// DTOs, and separate IPCResult cases. A hook completion can never be
// mistaken for an action completion: hook approval plants one exact-command
// allow-once grant, never an `AgentInstance` ActionApprovalGrant (F3).
//
// Descriptive DTOs only. The service re-validates every decisive call
// against its retained challenge, the authenticated peer, the bound UI
// connection, the pending row, and expiry. Decoded data alone is never
// authority.

// MARK: - Operator UI bridge (rvd ↔ RVOperatorUI, hook mode)

// Narrow UI service API for hook reviews. No generic mutation endpoint.
public enum UIHookBridgeRequest: Sendable, Equatable {
    case hookList
    case hookBind(approvalID: String)
    case hookComplete(UIHookCompletion)
    case hookDeny(UIHookDeny)
    case hookCancel(approvalID: String)
    case hookStatus(approvalID: String)
}

extension UIHookBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case hookList
        case hookBind
        case hookComplete
        case hookDeny
        case hookCancel
        case hookStatus
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hookList:
            try container.encode(EmptyPayload(), forKey: .hookList)
        case .hookBind(let approvalID):
            try container.encode(approvalID, forKey: .hookBind)
        case .hookComplete(let completion):
            try container.encode(completion, forKey: .hookComplete)
        case .hookDeny(let deny):
            try container.encode(deny, forKey: .hookDeny)
        case .hookCancel(let approvalID):
            try container.encode(approvalID, forKey: .hookCancel)
        case .hookStatus(let approvalID):
            try container.encode(approvalID, forKey: .hookStatus)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.hookList) {
            self = .hookList
        } else if let approvalID = try container.decodeIfPresent(String.self, forKey: .hookBind) {
            self = .hookBind(approvalID: approvalID)
        } else if let completion = try container.decodeIfPresent(
            UIHookCompletion.self, forKey: .hookComplete)
        {
            self = .hookComplete(completion)
        } else if let deny = try container.decodeIfPresent(UIHookDeny.self, forKey: .hookDeny) {
            self = .hookDeny(deny)
        } else if let approvalID = try container.decodeIfPresent(String.self, forKey: .hookCancel) {
            self = .hookCancel(approvalID: approvalID)
        } else if let approvalID = try container.decodeIfPresent(String.self, forKey: .hookStatus) {
            self = .hookStatus(approvalID: approvalID)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown UIHookBridgeRequest")
            )
        }
    }
}

/// Explicit allow-once completion. The UI reports its fresh
/// device-owner-authentication outcome; descriptive only until the service
/// validates peer, connection, challenge, row, bindings, and liveness.
public struct UIHookCompletion: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let approvalID: String
    public let outcome: UIAuthenticationOutcome

    public init(challengeID: UUID, approvalID: String, outcome: UIAuthenticationOutcome) {
        self.challengeID = challengeID
        self.approvalID = approvalID
        self.outcome = outcome
    }
}

/// Explicit deny for the exact bound review. No authentication: deny grants
/// nothing. Still bound to the live challenge so one connection cannot deny
/// another connection's review.
public struct UIHookDeny: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let approvalID: String

    public init(challengeID: UUID, approvalID: String) {
        self.challengeID = challengeID
        self.approvalID = approvalID
    }
}

/// Service-issued hook-review challenge projection, retained verbatim by
/// the UI from review through completion. Advisory timing only; service
/// monotonic state decides.
public struct UIHookChallengeDTO: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let approvalID: String
    public let actionFingerprint: String
    public let uiConnectionID: UUID
    public let issuedWall: Date
    public let advisoryLifetimeSeconds: Double

    public init(
        challengeID: UUID, approvalID: String, actionFingerprint: String,
        uiConnectionID: UUID, issuedWall: Date, advisoryLifetimeSeconds: Double
    ) {
        self.challengeID = challengeID
        self.approvalID = approvalID
        self.actionFingerprint = actionFingerprint
        self.uiConnectionID = uiConnectionID
        self.issuedWall = issuedWall
        self.advisoryLifetimeSeconds = advisoryLifetimeSeconds
    }
}

/// One reviewable pending hook wait, projected for trusted display.
///
/// All fields derive from the service's retained row. The exact command is
/// shown so the human reviews exactly what the allow-once would release;
/// secret-shaped fragments are redacted for display while the authorization
/// binds the unredacted fingerprint, shown here so the exact authority is
/// inspectable. This projection travels the authenticated operator-UI
/// channel only — never the `pendingList` IPC read.
public struct UIHookReviewItemDTO: Sendable, Equatable, Codable {
    public let approvalID: String
    public let host: String
    public let session: String
    public let actionKind: String
    public let exactCommand: String
    public let workingDirectory: String
    public let policyReason: String
    public let actionFingerprint: String
    public let status: String
    public let advisoryExpiresWall: Date?

    public init(
        approvalID: String, host: String, session: String, actionKind: String,
        exactCommand: String, workingDirectory: String, policyReason: String,
        actionFingerprint: String, status: String, advisoryExpiresWall: Date?
    ) {
        self.approvalID = approvalID
        self.host = host
        self.session = session
        self.actionKind = actionKind
        self.exactCommand = exactCommand
        self.workingDirectory = workingDirectory
        self.policyReason = policyReason
        self.actionFingerprint = actionFingerprint
        self.status = status
        self.advisoryExpiresWall = advisoryExpiresWall
    }
}

public struct UIHookReviewListDTO: Sendable, Equatable, Codable {
    public let items: [UIHookReviewItemDTO]

    public init(items: [UIHookReviewItemDTO]) {
        self.items = items
    }
}

/// Bound hook review: the retained challenge plus the item under review.
public struct UIHookChallengeBundleDTO: Sendable, Equatable, Codable {
    public let challenge: UIHookChallengeDTO
    public let item: UIHookReviewItemDTO

    public init(challenge: UIHookChallengeDTO, item: UIHookReviewItemDTO) {
        self.challenge = challenge
        self.item = item
    }
}

/// Safe hook-review status projection. Never grant contents, never authority.
public struct UIHookStatusDTO: Sendable, Equatable, Codable {
    public let approvalID: String
    public let status: String

    public init(approvalID: String, status: String) {
        self.approvalID = approvalID
        self.status = status
    }
}
