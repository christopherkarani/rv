/// Product Ask on the hook door. Not a `Decision` case.
///
/// NON-AUTHORITATIVE for Secrets/MCP (Step 8 fence): a `.allow` here is a
/// legacy hook-transport answer, never principal-bound authorization. Future
/// sensitive mediation must require `AuthenticatedAgentContext` + typed
/// `ProposedAction` + principal-bound policy (+ Step 6 human approval for
/// ASK), and must never treat this verdict as authority.
///
/// Step 8B: `.ask` encodes deny-with-guidance on every host and records a
/// pending row for RVOperatorUI. The agent retries after human approval;
/// the retry consumes the planted grant through the ordinary evaluate path.
public enum HostAskVerdict: Sendable, Equatable {
    case allow
    case deny
    case ask
}

/// Hard-policy projection onto the hook-live review boundary.
///
/// Step 8B: host-native spend is removed. Human-required operations route
/// to RVOperatorUI (or TTY allow-once) plus agent retry; the host's Ask UI
/// is never authoritative. Host capability metadata lives in
/// `HostApprovalCapability` (routing only, never authority).
public enum HostNativeAsk {
    public static let leftoverAskDeny = Deny(
        ruleID: RuleID(pack: ActionPolicyEngine.Builtin.pack, pattern: "leftover-ask"),
        reason: "Ask is not a permit."
    )

    /// Projects hard policy onto the hook-live review boundary.
    /// Uncovered actions remain quiet on the hook door until typed effects are
    /// available; shadow review owns the separate review-eligible projection.
    public static func hookBound(_ decision: HardPolicyDecision) -> BoundReview {
        switch decision {
        case .hardAllow:
            return .allow
        case .hardDeny(let deny):
            return .deny(deny)
        case .mandatoryHuman(let deny):
            return .mandatoryHuman(deny)
        case .reviewEligible:
            return .allow
        }
    }

    /// Evaluates a proposed action with the pack result as its fallback, then
    /// projects that hard decision onto the hook-live review boundary.
    public static func hookBound(
        result: EvaluationResult,
        action: ProposedAction,
        context: ReviewContext
    ) -> BoundReview {
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: context,
            policy: EffectiveActionPolicy(packFallback: PackFallback(result))
        )
        return hookBound(verdict.decision)
    }

    /// A leftover unused ask token is never a permit.
    public static let leftoverAskIsPermit = false
}
