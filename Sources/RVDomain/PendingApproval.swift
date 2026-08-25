import Foundation

/// Durable identifier for one pending approval. Replay of the same id cannot
/// authorize a different action.
public struct ApprovalID: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Agent execution identity bound onto a pending approval.
public struct AgentIdentity: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Session execution identity bound onto a pending approval.
public struct SessionIdentity: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Session plus agent the pending record is allowed to resume.
public struct ApprovalIdentity: Hashable, Sendable, Equatable, Codable {
    public var session: SessionIdentity
    public var agent: AgentIdentity

    public init(session: SessionIdentity, agent: AgentIdentity) {
        self.session = session
        self.agent = agent
    }
}

/// Why a host adapter asked RV to wait for a human.
public enum ApprovalReason: String, Sendable, Equatable, Codable {
    case mandatoryHuman
    case reviewAsk
    case hostAsk
}

/// Opaque host resume token. Meaning is host-defined; RV only stores and returns it.
public struct ApprovalResumeToken: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How the waiting host path continues after a resolution is consumed.
public enum ApprovalContinuation: Sendable, Equatable, Codable {
    case hostNative
    case resume(ApprovalResumeToken)
    case retry(ActionFingerprint)

    private enum CodingKeys: String, CodingKey {
        case kind
        case token
        case actionFingerprint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostNative:
            try container.encode("hostNative", forKey: .kind)
        case .resume(let token):
            try container.encode("resume", forKey: .kind)
            try container.encode(token, forKey: .token)
        case .retry(let fingerprint):
            try container.encode("retry", forKey: .kind)
            try container.encode(fingerprint, forKey: .actionFingerprint)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hostNative":
            self = .hostNative
        case "resume":
            self = .resume(try container.decode(ApprovalResumeToken.self, forKey: .token))
        case "retry":
            self = .retry(try container.decode(ActionFingerprint.self, forKey: .actionFingerprint))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown ApprovalContinuation"
            )
        }
    }
}

/// Human decision for this request only. Not a grant ledger or Always Allow preview.
public enum ApprovalDecision: String, Sendable, Equatable, Codable {
    case allowOnce
    case createRule
    case deny

    /// `allowOnce` and `createRule` may authorize the bound fingerprint once.
    public var authorizesExactAction: Bool {
        switch self {
        case .allowOnce, .createRule:
            return true
        case .deny:
            return false
        }
    }
}

/// What happens when no human arrives before `expiresAt`.
public enum ApprovalTimeoutPolicy: String, Sendable, Equatable, Codable {
    /// Leave the request awaiting a human past `expiresAt`.
    case keepWaiting
    /// Close as a deny when `now` is after `expiresAt`.
    case autoDeny
    /// Fail the waiting task when `now` is after `expiresAt`. Never authorizes.
    case failTask
}

/// Recorded human decision. Consumption is tracked on `PendingApproval`.
public struct ApprovalResolution: Sendable, Equatable, Codable {
    public var decision: ApprovalDecision
    public var resolvedAt: Date

    public init(decision: ApprovalDecision, resolvedAt: Date) {
        self.decision = decision
        self.resolvedAt = resolvedAt
    }
}

/// Policy that closed a request after `expiresAt`.
public struct ApprovalTimeoutEnding: Sendable, Equatable, Codable {
    public var policy: ApprovalTimeoutPolicy
    public var at: Date

    public init(policy: ApprovalTimeoutPolicy, at: Date) {
        self.policy = policy
        self.at = at
    }
}

/// Closed lifecycle. Terminal states cannot later authorize execution.
public enum PendingApprovalState: Sendable, Equatable, Codable {
    case awaitingHuman
    case resolved(ApprovalResolution)
    case expired(at: Date)
    case canceled(at: Date)
    case timedOut(ApprovalTimeoutEnding)

    private enum CodingKeys: String, CodingKey {
        case kind
        case resolution
        case at
        case timeout
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .awaitingHuman:
            try container.encode("awaitingHuman", forKey: .kind)
        case .resolved(let resolution):
            try container.encode("resolved", forKey: .kind)
            try container.encode(resolution, forKey: .resolution)
        case .expired(let at):
            try container.encode("expired", forKey: .kind)
            try container.encode(at, forKey: .at)
        case .canceled(let at):
            try container.encode("canceled", forKey: .kind)
            try container.encode(at, forKey: .at)
        case .timedOut(let ending):
            try container.encode("timedOut", forKey: .kind)
            try container.encode(ending, forKey: .timeout)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "awaitingHuman":
            self = .awaitingHuman
        case "resolved":
            self = .resolved(try container.decode(ApprovalResolution.self, forKey: .resolution))
        case "expired":
            self = .expired(at: try container.decode(Date.self, forKey: .at))
        case "canceled":
            self = .canceled(at: try container.decode(Date.self, forKey: .at))
        case "timedOut":
            self = .timedOut(try container.decode(ApprovalTimeoutEnding.self, forKey: .timeout))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown PendingApprovalState"
            )
        }
    }
}

/// Host-adapter create payload. No UI state.
public struct PendingApprovalRequest: Sendable, Equatable {
    public static let defaultTTL: TimeInterval = 15 * 60

    public var id: ApprovalID
    public var identity: ApprovalIdentity
    public var action: ProposedAction
    public var reason: ApprovalReason
    public var continuation: ApprovalContinuation
    public var timeoutPolicy: ApprovalTimeoutPolicy
    public var ttl: TimeInterval

    public init(
        id: ApprovalID,
        identity: ApprovalIdentity,
        action: ProposedAction,
        reason: ApprovalReason,
        continuation: ApprovalContinuation,
        timeoutPolicy: ApprovalTimeoutPolicy,
        ttl: TimeInterval = PendingApprovalRequest.defaultTTL
    ) {
        self.id = id
        self.identity = identity
        self.action = action
        self.reason = reason
        self.continuation = continuation
        self.timeoutPolicy = timeoutPolicy
        self.ttl = ttl
    }
}

/// Durable pending-approval record. Bound to identity + `action.fingerprint`.
public struct PendingApproval: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var identity: ApprovalIdentity
    public var action: ProposedAction
    public var reason: ApprovalReason
    public var continuation: ApprovalContinuation
    public var timeoutPolicy: ApprovalTimeoutPolicy
    public var createdAt: Date
    public var expiresAt: Date
    public var state: PendingApprovalState
    public var consumedAt: Date?

    public init(
        id: ApprovalID,
        identity: ApprovalIdentity,
        action: ProposedAction,
        reason: ApprovalReason,
        continuation: ApprovalContinuation,
        timeoutPolicy: ApprovalTimeoutPolicy,
        createdAt: Date,
        expiresAt: Date,
        state: PendingApprovalState,
        consumedAt: Date? = nil
    ) {
        self.id = id
        self.identity = identity
        self.action = action
        self.reason = reason
        self.continuation = continuation
        self.timeoutPolicy = timeoutPolicy
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.consumedAt = consumedAt
    }

    public var fingerprint: ActionFingerprint {
        action.fingerprint
    }

    /// True only for an unconsumed authorizing resolution of this exact bind.
    public func authorizes(_ fingerprint: ActionFingerprint, identity: ApprovalIdentity) -> Bool {
        guard consumedAt == nil else { return false }
        guard self.identity == identity, self.fingerprint == fingerprint else { return false }
        if case .retry(let retryFingerprint) = continuation, retryFingerprint != fingerprint {
            return false
        }
        guard case .resolved(let resolution) = state else { return false }
        return resolution.decision.authorizesExactAction
    }
}

/// Exactly-once delivery of a human (or deny) resolution to the host path.
public struct ApprovalConsumption: Sendable, Equatable {
    public var approval: PendingApproval
    public var decision: ApprovalDecision

    public init(approval: PendingApproval, decision: ApprovalDecision) {
        self.approval = approval
        self.decision = decision
    }
}

/// Subscribe events the Mac app can sit on later. Not a transport.
public enum PendingApprovalEvent: Sendable, Equatable {
    case created(PendingApproval)
    case resolved(PendingApproval)
    case expired(PendingApproval)
    case canceled(PendingApproval)
    case timedOut(PendingApproval)
    case consumed(PendingApproval)
}

public enum PendingApprovalError: Error, Sendable, Equatable {
    case invalidRequest
    case duplicateID
    case notFound
    case alreadyResolved
    case expired
    case canceled
    case timedOut
    case fingerprintMismatch
    case identityMismatch
    case continuationMismatch
    case alreadyConsumed
    case notResolved
    case encodeFailed
    case lockFailed
}
