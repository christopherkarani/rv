import RVDomain

/// Pure plan for deferred IPC `allowOnce`. Effects stay in `ApprovalRuntime`.
enum PendingAllowOncePlan: Equatable, Sendable {
    /// CAS-resolve first, then plant a PolicyGate grant and consume the wait.
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
            guard let cwd, HookAuthorization.isUnlockable(result: peek, cwd: cwd) else {
                return .refuse
            }
            return .plant(matchingView: peek.matchingView, cwd: cwd)
        }
    }
}

/// Pause plan, then grant plan only on `spendThenAllow`.
enum HostAskResolvePlan: Equatable, Sendable {
    case spend(PendingAllowOncePlan)
    case ledgerDeny
    case denyOrTTY
}

enum HostAskResolve {
    static func plan(
        host: HookHost,
        continuation: ApprovalContinuation,
        decision: ApprovalDecision,
        peek: EvaluationResult?,
        cwd: WorkingDirectory?
    ) -> HostAskResolvePlan {
        switch HostNativeAsk.resolve(
            host: host,
            continuation: continuation,
            decision: decision
        ) {
        case .deny:
            return .ledgerDeny
        case .denyOrTTY:
            return .denyOrTTY
        case .spendThenAllow:
            guard let peek else { return .spend(.refuse) }
            return .spend(PendingAllowOncePlanner.plan(peek: peek, cwd: cwd))
        }
    }
}
