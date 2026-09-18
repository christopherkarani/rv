/// Deny the Policy gate could spend. Ask, mint, and spend share `HookAuthorization`.
public enum UnlockableDeny: Sendable {
    /// Yes for an unpinned deny with cwd and a nonempty matching view.
    public static func matches(result: EvaluationResult, cwd: WorkingDirectory?) -> Bool {
        HookAuthorization.isUnlockable(result: result, cwd: cwd)
    }

    /// Pin half: secrets, builtin.action, unwrap-limited analysis, protected-path.
    public static func isPinned(_ result: EvaluationResult) -> Bool {
        HookAuthorization.isPinned(result)
    }
}
