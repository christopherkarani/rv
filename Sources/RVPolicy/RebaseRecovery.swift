import RVDomain

/// Pure eligibility for auto-allowing rebase-documented git discards.
public enum RebaseRecovery: Sendable {
    public static func isEligible(result: EvaluationResult) -> Bool {
        guard case .deny(let deny) = result.decision else {
            return false
        }
        if isNeverEligibleRule(deny.ruleID) {
            return false
        }
        if let action = result.analysis.gitAction {
            return isEligibleGitAction(action)
        }
        return isEligiblePackRule(deny.ruleID)
    }

    private static func isNeverEligibleRule(_ ruleID: RuleID) -> Bool {
        switch ruleID.pattern {
        case "reset-hard", "reset-merge", "clean-force":
            return true
        default:
            return ruleID.pattern.hasPrefix("push-force-")
        }
    }

    private static func isEligibleGitAction(_ action: GitAction) -> Bool {
        switch action {
        case .discardWorktree:
            return true
        case .restore(_, _, true, _):
            return true
        case .reset, .clean, .push, .switchBranch, .stash,
            .createBranch, .deleteBranch, .deleteTag, .rebase,
            .restore(_, _, false, _):
            return false
        }
    }

    private static func isEligiblePackRule(_ ruleID: RuleID) -> Bool {
        switch ruleID.pattern {
        case "checkout-discard", "checkout-ref-discard",
            "restore-worktree", "restore-worktree-explicit":
            return true
        default:
            return false
        }
    }
}
