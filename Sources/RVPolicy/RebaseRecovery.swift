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
    /// `HookAuthorization` pin.
    private static func isUnoverridableHardStop(_ result: EvaluationResult) -> Bool {
        if case .deny(let deny) = result.decision,
           BuiltinRule(deny.ruleID) == .workingTreeDiscard
        {
            return false
        }
        return HookAuthorization.isPinned(result)
    }

    /// The host MCP config guard is never lifted: restoring `.mcp.json`
    /// mid-rebase is still a write of a host MCP config.
    private static func isNeverEligibleRule(_ ruleID: RuleID) -> Bool {
        if ruleID == MCPHostConfigPaths.ruleID { return true }
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
        case .restore(_, .worktree, _), .restore(_, .worktreeAndIndex, _):
            return true
        case .reset, .clean, .push, .pushUnparsed, .deleteRemoteRef, .switchBranch, .stash,
            .createBranch, .deleteBranch, .deleteTag, .rebase,
            .restore(_, .index, _):
            return false
        }
    }
}
