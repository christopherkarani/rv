/// Pack deny the Policy gate could spend. Ask, mint, and spend share this.
public enum UnlockableDeny: Sendable {
    /// Yes only for an unpinned pack deny with cwd and a nonempty matching view.
    public static func matches(result: EvaluationResult, cwd: WorkingDirectory?) -> Bool {
        guard case .deny = result.decision else { return false }
        guard isPinned(result) == false else { return false }
        guard cwd != nil else { return false }
        guard result.matchingView.isEmpty == false else { return false }
        return true
    }

    /// Pin half: secrets, builtin.action, unwrap-limited analysis, protected-path.
    public static func isPinned(_ result: EvaluationResult) -> Bool {
        if case .deny(let deny) = result.decision, isPinnedPack(deny) {
            return true
        }
        if result.analysis.innermost == .unwrapLimited {
            return true
        }
        if result.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath {
            return true
        }
        return false
    }

    private static func isPinnedPack(_ deny: Deny) -> Bool {
        deny.ruleID.pack == .coreSecrets
            || deny.ruleID.pack == ActionPolicyEngine.Builtin.pack
    }
}
