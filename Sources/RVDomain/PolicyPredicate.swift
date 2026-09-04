/// Closed policy matcher. W1 is git-push only; nil force or branch is unspecified.
/// Write `GitPushForce.none` for a non-force push; `.none` is Optional.none.
public enum PolicyPredicate: Sendable, Equatable, Codable {
    /// Matches `GitAction.push`. `supportingCommand` is not part of this form.
    case gitPush(force: GitPushForce?, branch: String?)
}
