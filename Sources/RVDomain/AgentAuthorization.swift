/// A proposal that hard policy authorized. Not a permit to spawn a process.
///
/// Only `AgentAuthorization.decide` constructs this in production. The
/// memberwise initializer is a `@testable` seam, like `AgentProcessRequest`.
public struct AllowedAction: Sendable, Equatable {
    public let action: ProposedAction
    public let explanation: ActionPolicyExplanation

    init(action: ProposedAction, explanation: ActionPolicyExplanation) {
        self.action = action
        self.explanation = explanation
    }
}

/// A proposal that hard policy rejected. No `AllowedAction` exists for this decision.
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

    private static func map(
        action: ProposedAction,
        hardDecision: HardPolicyDecision,
        explanation: ActionPolicyExplanation,
        bound: BoundReview
    ) -> AgentAuthorization {
        if case .hardDeny(let deny) = hardDecision {
            return .denied(
                DeniedAction(action: action, deny: deny, explanation: explanation)
            )
        }
        switch bound {
        case .allow:
            if case .mandatoryHuman(let deny) = hardDecision {
                return .pending(
                    PendingAuthorization(
                        action: action,
                        reason: .mandatoryHuman,
                        deny: deny,
                        explanation: explanation
                    )
                )
            }
            return .allowed(AllowedAction(action: action, explanation: explanation))
        case .deny(let deny):
            return .denied(
                DeniedAction(action: action, deny: deny, explanation: explanation)
            )
        case .mandatoryHuman(let deny):
            let reason: ApprovalReason
            switch hardDecision {
            case .reviewEligible:
                reason = .reviewAsk
            case .mandatoryHuman, .hardAllow, .hardDeny:
                reason = .mandatoryHuman
            }
            return .pending(
                PendingAuthorization(
                    action: action,
                    reason: reason,
                    deny: deny,
                    explanation: explanation
                )
            )
        }
    }
}
