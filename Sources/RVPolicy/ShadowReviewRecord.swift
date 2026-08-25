import RVDomain

/// Deterministic/human live outcome recorded next to a shadow review.
public enum ShadowLiveOutcome: String, Sendable, Equatable, Codable {
    case allow
    case deny
    case askHuman
}

/// Why a shadow review lacked minimum semantic context.
public enum ShadowMissingContextReason: String, Sendable, Equatable, Codable {
    case repositoryName
    case currentBranch
    case workingDirectory
}

/// Tiny shadow-only record. Not the OPE-166 execution audit log.
public struct ShadowReviewRecord: Sendable, Equatable, Codable {
    public var providerID: ReviewerProviderID
    /// `true` only when the runner called `ActionReviewer.review`.
    public var invoked: Bool
    public var decision: ReviewDecision?
    public var confidence: ReviewerConfidence?
    public var rationaleCategory: ReviewRationaleCategory?
    public var liveOutcome: ShadowLiveOutcome
    public var latencyNanoseconds: UInt64
    public var disagreesWithLive: Bool
    public var missingContextReasons: [ShadowMissingContextReason]
    public var modelUnavailable: Bool

    public init(
        providerID: ReviewerProviderID,
        invoked: Bool,
        decision: ReviewDecision?,
        confidence: ReviewerConfidence?,
        rationaleCategory: ReviewRationaleCategory?,
        liveOutcome: ShadowLiveOutcome,
        latencyNanoseconds: UInt64,
        disagreesWithLive: Bool,
        missingContextReasons: [ShadowMissingContextReason],
        modelUnavailable: Bool
    ) {
        self.providerID = providerID
        self.invoked = invoked
        self.decision = decision
        self.confidence = confidence
        self.rationaleCategory = rationaleCategory
        self.liveOutcome = liveOutcome
        self.latencyNanoseconds = latencyNanoseconds
        self.disagreesWithLive = disagreesWithLive
        self.missingContextReasons = missingContextReasons
        self.modelUnavailable = modelUnavailable
    }
}

/// Live decision plus the separate shadow record. The two are never combined here.
public struct ShadowReviewResult: Sendable, Equatable {
    public var live: BoundReview
    public var shadow: ShadowReviewRecord

    public init(live: BoundReview, shadow: ShadowReviewRecord) {
        self.live = live
        self.shadow = shadow
    }
}

extension ShadowLiveOutcome {
    public init(_ live: BoundReview) {
        switch live {
        case .allow:
            self = .allow
        case .deny:
            self = .deny
        case .mandatoryHuman:
            self = .askHuman
        }
    }
}

enum ShadowMissingContext {
    static func reasons(in request: ReviewRequest) -> [ShadowMissingContextReason] {
        var reasons: [ShadowMissingContextReason] = []
        if request.context.repository.name == nil {
            reasons.append(.repositoryName)
        }
        if request.context.repository.currentBranch == nil {
            reasons.append(.currentBranch)
        }
        switch request.action {
        case .shell(let shell):
            if shell.scope.workingDirectory == nil {
                reasons.append(.workingDirectory)
            }
        }
        return reasons
    }
}

enum ShadowDisagreement {
    static func disagrees(live: BoundReview, decision: ReviewDecision?) -> Bool {
        guard let decision else {
            return false
        }
        switch (live, decision) {
        case (.allow, .deny), (.deny, .allow), (.mandatoryHuman, .allow):
            return true
        default:
            return false
        }
    }
}
