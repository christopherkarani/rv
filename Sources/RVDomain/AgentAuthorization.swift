/// A proposal that policy authorized. Not a permit to spawn a process.
///
/// Produced for `hardAllow`, for `reviewEligible` after a sufficient
/// aligned allow review, or by `resolve` after a human `allowOnce`.
/// `decide` and `resolve` construct this in production. The memberwise
/// initializer is a `@testable` seam, like `AgentProcessRequest`.
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
/// Produced for `hardDeny`, for `reviewEligible` after a sufficient
/// aligned deny review, or by `resolve` after a human `deny`.
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

/// Why `decide` asked a human. Ledger `ApprovalReason.hostAsk` is not a case.
public enum RuntimeAskReason: Sendable, Equatable {
    case mandatoryHuman
    case reviewAsk

    /// Ledger spelling for the admission wire. `hostAsk` is not representable.
    var ledgerReason: ApprovalReason {
        switch self {
        case .mandatoryHuman:
            .mandatoryHuman
        case .reviewAsk:
            .reviewAsk
        }
    }
}

/// Human click the agent door can apply. Ledger `ApprovalDecision.createRule` is not a case.
public enum AgentHumanDecision: Sendable, Equatable {
    case allowOnce
    case deny
}

/// ASK intent. Human approval is required before an allowed value can exist.
///
/// Produced for `mandatoryHuman`, or for `reviewEligible` without a sufficient
/// review. `reason` is a runtime ask, not ledger `hostAsk`.
///
/// Not a `PendingApproval` ledger row: no clock, store identity, or expiry.
public struct PendingAuthorization: Sendable, Equatable {
    public let action: ProposedAction
    public let reason: RuntimeAskReason
    public let deny: Deny
    public let explanation: ActionPolicyExplanation

    init(
        action: ProposedAction,
        reason: RuntimeAskReason,
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
/// Produced by `decide`. Human approval of pending is `resolve`, not a
/// second `decide`. This door must not use `HostNativeAsk.hookBound`
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

    /// Maps a ledger click onto the agent alphabet.
    ///
    /// `allowOnce` and `deny` succeed. `createRule` does not mint a rule on
    /// this door.
    package static func humanDecision(
        _ decision: ApprovalDecision
    ) -> Result<AgentHumanDecision, AgentApprovalError> {
        switch decision {
        case .allowOnce:
            return .success(.allowOnce)
        case .deny:
            return .success(.deny)
        case .createRule:
            return .failure(.ruleCreationUnsupported)
        }
    }

    /// Turns ASK intent into a capability or a denial. Does not re-run `decide`.
    ///
    /// `allowOnce` lifts `mandatoryHuman` and `reviewAsk`. `deny` keeps the
    /// pending denial. Channel failure produces no `AllowedAction`. Ledger
    /// `createRule` never reaches this function; `humanDecision` rejects it.
    ///
    /// - Parameters:
    ///   - pending: ASK intent from `decide`. Holding one is not a capability.
    ///   - approval: Human allow-once or deny, or a channel error. Timeout and
    ///     transport failures map to `approvalUnavailable` at the caller.
    /// - Returns: Allowed or denied, or a typed approval-channel error.
    public static func resolve(
        _ pending: PendingAuthorization,
        approval: Result<AgentHumanDecision, AgentApprovalError>
    ) -> Result<ResolvedAuthorization, AgentApprovalError> {
        switch approval {
        case .failure(let error):
            return .failure(error)
        case .success(.allowOnce):
            return .success(
                .allowed(
                    AllowedAction(
                        action: pending.action,
                        explanation: pending.explanation
                    )
                )
            )
        case .success(.deny):
            return .success(
                .denied(
                    DeniedAction(
                        action: pending.action,
                        deny: pending.deny,
                        explanation: pending.explanation
                    )
                )
            )
        }
    }

    /// Same allow / ask / deny split `LocalExecutor` and runtime admission use.
    ///
    /// Pending without an approval stays pending. Ledger `createRule` fails in
    /// `humanDecision` before `resolve`, so it is not an `AllowedAction`.
    public static func step(
        _ authorization: AgentAuthorization,
        approval: Result<ApprovalDecision, AgentApprovalError>? = nil
    ) -> AuthorizationStep {
        switch authorization {
        case .allowed(let allowed):
            return .execute(allowed)
        case .denied(let denied):
            return .denied(denied)
        case .pending(let pending):
            guard let approval else {
                return .awaitingApproval(pending)
            }
            switch resolve(pending, approval: approval.flatMap({ humanDecision($0) })) {
            case .failure(let error):
                return .approvalFailed(error)
            case .success(.denied(let denied)):
                return .denied(denied)
            case .success(.allowed(let allowed)):
                return .execute(allowed)
            }
        }
    }
}

/// What an already-decided authorization may do next. Ask is not execution.
public enum AuthorizationStep: Sendable, Equatable {
    case execute(AllowedAction)
    case denied(DeniedAction)
    case awaitingApproval(PendingAuthorization)
    case approvalFailed(AgentApprovalError)
}

/// Human-resolved ASK. Pending is unrepresentable.
public enum ResolvedAuthorization: Sendable, Equatable {
    case allowed(AllowedAction)
    case denied(DeniedAction)
}

/// Fail-closed approval-channel and unsupported-click errors.
///
/// Channel-down maps to `approvalUnavailable` at the caller. `createRule`
/// maps to `ruleCreationUnsupported` in `humanDecision`. This type is not
/// a ledger timeout and does not mint a rule.
public enum AgentApprovalError: Error, Sendable, Equatable {
    /// The approval channel did not return a human decision.
    case approvalUnavailable
    /// `createRule` is not `allowOnce` and does not mint a rule this slice.
    case ruleCreationUnsupported
}
