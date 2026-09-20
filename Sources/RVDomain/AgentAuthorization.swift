/// A proposal that policy authorized. Not a permit to spawn a process.
///
/// Produced for `hardAllow`, or for `reviewEligible` after a sufficient
/// aligned allow review. Only `AgentAuthorization.decide` constructs this
/// in production. The memberwise initializer is a `@testable` seam, like
/// `AgentProcessRequest`.
public struct AllowedAction: Sendable, Equatable {
    public let action: ProposedAction
    public let explanation: ActionPolicyExplanation

    init(action: ProposedAction, explanation: ActionPolicyExplanation) {
        self.action = action
        self.explanation = explanation
    }
}

/// A proposal that policy rejected. No `AllowedAction` exists for this decision.
///
/// Produced for `hardDeny`, or for `reviewEligible` after a sufficient
/// aligned deny review.
public struct DeniedAction: Sendable, Equatable {
    public let action: ProposedAction
    public let deny: Deny
    public let explanation: ActionPolicyExplanation

    init(action: ProposedAction, deny: Deny, explanation: ActionPolicyExplanation) {
        self.action = action
        self.deny = deny
        self.explanation = explanation
    }
}

/// ASK intent. Human approval is required before an allowed value can exist.
///
/// Produced for `mandatoryHuman`, or for `reviewEligible` without a sufficient
/// review. `reason` is never `.hostAsk`.
///
/// Not a `PendingApproval` ledger row: no clock, store identity, or expiry.
public struct PendingAuthorization: Sendable, Equatable {
    public let action: ProposedAction
    public let reason: ApprovalReason
    public let deny: Deny
    public let explanation: ActionPolicyExplanation

    init(
        action: ProposedAction,
        reason: ApprovalReason,
        deny: Deny,
        explanation: ActionPolicyExplanation
    ) {
        self.action = action
        self.reason = reason
        self.deny = deny
        self.explanation = explanation
    }
}

/// Exhaustive runtime policy outcome. Ask is a case, not pack `Decision.deny`.
///
/// Produced by `decide`. This door must not use `HostNativeAsk.hookBound`
/// (quiet-allows `reviewEligible`) or `ActionPolicyEngine.bind` (probed git).
/// `BoundReview.decision` collapses Ask to deny and is not the runtime case.
public enum AgentAuthorization: Sendable, Equatable {
    case allowed(AllowedAction)
    case pending(PendingAuthorization)
    case denied(DeniedAction)

    /// Compiles a proposal through `ActionPolicyEngine` and `ReviewBind`.
    ///
    /// Default review is `.failure(.unsupported)`: no reviewer ran. That is
    /// fail-closed for `reviewEligible`. Callers await a reviewer outside this
    /// function and pass `.success(review)` when they have one.
    ///
    /// Always calls `evaluate(action:context:policy:gitWorld:)`. Default
    /// `gitWorld` is `.unprobed`, matching the Engine door.
    ///
    /// Hard zones ignore `BoundReview`. `.hardDeny` is always denied,
    /// `.mandatoryHuman` is always pending `.mandatoryHuman`, and
    /// `.hardAllow` is always allowed. Review can change only
    /// `.reviewEligible`.
    ///
    /// - Parameters:
    ///   - action: Proposal to authorize. Holding one is not a capability.
    ///   - context: Repository and environment facts. Empty by default.
    ///   - policy: Overlay, pack fallback, and typed rules. Empty by default.
    ///   - gitWorld: Whether git facts were injected. Default `.unprobed`.
    ///   - review: Advisory review. Default is that no reviewer ran.
    /// - Returns: An exhaustive allowed, pending, or denied outcome.
    public static func decide(
        action: ProposedAction,
        context: ReviewContext = ReviewContext(repository: RepositoryReviewContext()),
        policy: EffectiveActionPolicy = .empty,
        gitWorld: GitAnalysisWorld = .unprobed,
        review: Result<ActionReview, ActionReviewerError> = .failure(.unsupported)
    ) -> AgentAuthorization {
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: context,
            policy: policy,
            gitWorld: gitWorld
        )
        let bound = ReviewBind.apply(
            hardDecision: verdict.decision,
            review: review
        )
        return map(
            action: action,
            hardDecision: verdict.decision,
            explanation: verdict.explanation,
            bound: bound
        )
    }

    /// Hard zones win. `bound` is consulted only for `reviewEligible`.
    ///
    /// Internal so `@testable` tests can pin inconsistent pairs `ReviewBind`
    /// does not currently construct.
    static func map(
        action: ProposedAction,
        hardDecision: HardPolicyDecision,
        explanation: ActionPolicyExplanation,
        bound: BoundReview
    ) -> AgentAuthorization {
        switch hardDecision {
        case .hardDeny(let deny):
            return .denied(
                DeniedAction(action: action, deny: deny, explanation: explanation)
            )
        case .mandatoryHuman(let deny):
            return .pending(
                PendingAuthorization(
                    action: action,
                    reason: .mandatoryHuman,
                    deny: deny,
                    explanation: explanation
                )
            )
        case .hardAllow:
            return .allowed(AllowedAction(action: action, explanation: explanation))
        case .reviewEligible:
            switch bound {
            case .allow:
                return .allowed(AllowedAction(action: action, explanation: explanation))
            case .deny(let deny):
                return .denied(
                    DeniedAction(action: action, deny: deny, explanation: explanation)
                )
            case .mandatoryHuman(let deny):
                return .pending(
                    PendingAuthorization(
                        action: action,
                        reason: .reviewAsk,
                        deny: deny,
                        explanation: explanation
                    )
                )
            }
        }
    }
}
