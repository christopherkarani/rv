public enum PolicyGateAccess: Sendable, Equatable {
    case consider
    case skip
}

/// One hook-door authorization. Decided by policy, never by caller host.
///
/// Step 8B policy/transport split: `project` answers "does this operation
/// require human approval?" with no host input. Transport routing (which
/// approval surface, which wire bytes) happens downstream and can never
/// convert ASK into ALLOW.
public enum HookAuthorization: Sendable, Equatable {
    case allow
    case denyPinned
    case ask

    /// Which live results may consult PolicyGate. Semantic hard bind only:
    /// pack denials (`boundReview == nil`) and `mandatoryHuman` still reach
    /// PolicyGate so allow-once grants, allowlist, and rebase recovery apply.
    public static func policyGateAccess(for result: EvaluationResult) -> PolicyGateAccess {
        if case .deny = result.boundReview {
            return .skip
        }
        return .consider
    }

    /// Pinned when no human transport may ever allow it.
    public static func isPinned(_ result: EvaluationResult) -> Bool {
        if result.analysis.innermost == .unwrapLimited { return true }
        if let scope = result.analysis.filesystemAction?.primaryTarget?.scope,
            case .protectedPath = scope
        {
            return true
        }
        if case .deny = result.boundReview { return true }
        guard case .deny(let deny) = result.decision else { return false }
        if deny.ruleID.pack == .coreSecrets { return true }
        if deny.ruleID.pack == ActionPolicyEngine.Builtin.pack {
            // A carried mandatory-human bind is an explicit human-review
            // request: human transports may oblige. Any other builtin
            // deny (shared branch, outside repo, discard, leftover) pins.
            if case .mandatoryHuman = result.boundReview { return false }
            return true
        }
        return false
    }

    /// Unlockable when a human transport (RVOperatorUI or TTY allow-once)
    /// may allow exactly this action once.
    public static func isUnlockable(result: EvaluationResult, cwd: WorkingDirectory?) -> Bool {
        guard case .deny = result.decision else { return false }
        guard cwd != nil, result.matchingView.isEmpty == false else { return false }
        return isPinned(result) == false
    }

    /// Host-free policy: this operation requires human authorization.
    /// Either an unlockable deny or a carried mandatory-human bind with a
    /// spendable action shape. Indeterminate never asks: an unfinished
    /// evaluation is denied, not delegated to a human.
    public static func requiresHuman(result: EvaluationResult, cwd: WorkingDirectory?) -> Bool {
        if case .mandatoryHuman = result.boundReview,
            cwd != nil,
            result.matchingView.isEmpty == false
        {
            if case .indeterminate = result.decision {
                return false
            }
            return true
        }
        return isUnlockable(result: result, cwd: cwd)
    }

    /// Mint a TTY unlock code alongside the RVOperatorUI pending row.
    /// Exactly the asks: every human-approvable action is offered on both
    /// transports.
    public static func shouldMintUnlock(result: EvaluationResult, cwd: WorkingDirectory) -> Bool {
        project(result: result, cwd: cwd) == .ask
    }

    public var shouldMintUnlock: Bool {
        self == .ask
    }

    public var shouldRecordPending: Bool {
        self == .ask
    }

    /// Decides authorization only. `shouldRecordPending` and
    /// `shouldMintUnlock` drive transport. Callers must not branch on
    /// anything else.
    public static func project(
        result: EvaluationResult,
        cwd: WorkingDirectory?
    ) -> HookAuthorization {
        let bound = BoundReview.packProjected(from: result)
        switch bound {
        case .allow:
            if case .allow = result.decision {
                return .allow
            }
            return .denyPinned
        case .deny, .mandatoryHuman:
            if requiresHuman(result: result, cwd: cwd) {
                return .ask
            }
            return .denyPinned
        }
    }

    public var verdict: HostAskVerdict {
        switch self {
        case .allow:
            return .allow
        case .ask:
            return .ask
        case .denyPinned:
            return .deny
        }
    }
}
