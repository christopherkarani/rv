/// Closed evaluation zone. Carried on `ActionPolicyExplanation` so two runs
/// can compare zone + rule + reason without a full explain pipeline.
public enum ActionPolicyZone: String, Sendable, Equatable, Codable {
    case hardAllow
    case mandatoryHuman
    case hardDeny
    case reviewEligible
}

/// Deterministic hard-policy verdict produced by `ActionPolicyEngine`.
public enum HardPolicyDecision: Sendable, Equatable, Codable {
    case hardAllow
    case hardDeny(Deny)
    case mandatoryHuman(Deny)
    /// Reviewer advice may apply only in this zone. `fallback` is the Ask/Deny
    /// that wins when the review is missing, weak, or conflicting.
    case reviewEligible(fallback: Deny)

    public var zone: ActionPolicyZone {
        switch self {
        case .hardAllow:
            return .hardAllow
        case .hardDeny:
            return .hardDeny
        case .mandatoryHuman:
            return .mandatoryHuman
        case .reviewEligible:
            return .reviewEligible
        }
    }
}

/// Authorization after hard policy and optional advisory review.
public enum BoundReview: Sendable, Equatable {
    case allow
    case deny(Deny)
    case mandatoryHuman(Deny)

    /// Fail-closed projection onto evaluate `Decision`. Ask maps to deny.
    public var decision: Decision {
        switch self {
        case .allow:
            return .allow
        case .deny(let deny), .mandatoryHuman(let deny):
            return .deny(deny)
        }
    }
}

/// Pure bind. Reviewer identity is generic so RVPolicy / RVEngine stay untouched
/// when a provider is swapped.
public enum ReviewBind: Sendable {
    public static func apply(
        hardDecision: HardPolicyDecision,
        review: Result<ActionReview, ActionReviewerError>
    ) -> BoundReview {
        switch hardDecision {
        case .hardAllow:
            return .allow
        case .hardDeny(let deny):
            return .deny(deny)
        case .mandatoryHuman(let deny):
            return .mandatoryHuman(deny)
        case .reviewEligible(let fallback):
            return bindEligible(fallback: fallback, review: review)
        }
    }

    private static func bindEligible(
        fallback: Deny,
        review: Result<ActionReview, ActionReviewerError>
    ) -> BoundReview {
        switch review {
        case .failure:
            return .mandatoryHuman(fallback)
        case .success(let actionReview):
            guard actionReview.confidence.isSufficientToAdvise else {
                return .mandatoryHuman(fallback)
            }
            guard actionReview.hasConflictingRationale == false else {
                return .mandatoryHuman(fallback)
            }
            switch (actionReview.decision, actionReview.rationaleCategory) {
            case (.allow, .allow):
                return .allow
            case (.deny, .deny):
                return .deny(fallback)
            default:
                return .mandatoryHuman(fallback)
            }
        }
    }
}
