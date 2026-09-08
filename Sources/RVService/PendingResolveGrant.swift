import RVDomain

/// Pure plan for deferred IPC `allowOnce`. Effects stay in `ServiceRuntime`.
enum PendingAllowOncePlan: Equatable, Sendable {
    /// Plant a PolicyGate grant, then resolve + consume the wait.
    case plant(matchingView: MatchingView, cwd: WorkingDirectory)
    /// Peek already allows; resolve the wait and do not plant a second grant.
    case resolveWithoutGrant
    /// Hard bind, indeterminate, missing cwd/view, or not unlockable: leave awaiting.
    case refuse
}

enum PendingAllowOncePlanner {
    static func plan(peek: EvaluationResult, cwd: WorkingDirectory?) -> PendingAllowOncePlan {
        switch peek.decision {
        case .allow:
            return .resolveWithoutGrant
        case .indeterminate:
            return .refuse
        case .deny:
            if case .deny = peek.boundReview {
                return .refuse
            }
            guard let cwd, UnlockableDeny.matches(result: peek, cwd: cwd) else {
                return .refuse
            }
            return .plant(matchingView: peek.matchingView, cwd: cwd)
        }
    }
}
