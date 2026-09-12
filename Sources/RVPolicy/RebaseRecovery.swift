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
        if isUnoverridableHardStop(result) {
            return false
        }
        guard let action = result.analysis.gitAction else {
            return false
        }
        return isEligibleGitAction(action)
    }

    /// Rebase recovery may lift the working-tree-discard pin. Secrets,
    /// protected-path, unwrap-limited, and other hard stops stay denied via
    /// `UnlockableDeny`.
    private static func isUnoverridableHardStop(_ result: EvaluationResult) -> Bool {
        if case .deny(let deny) = result.decision,
           deny.ruleID == ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID
        {
            return false
        }
        return UnlockableDeny.isPinned(result)
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
}
