/// Whether the Policy gate may consider a live result. Host-free; no Ask.
public enum PolicyGateAccess: Sendable, Equatable {
    case skip
    case consider
}

/// One hook-door authorization. Ask, mint, record, and Policy-gate skip share this.
public enum HookAuthorization: Sendable, Equatable {
    case allow
    case denyPinned(Deny)
    case denyUnlockable(Deny)
    case ask(ApprovalContinuation)

    /// Semantic hard bind. Pack denials (`boundReview == nil`) and
    /// `mandatoryHuman` still reach PolicyGate (peek/apply and Host Ask).
    public static func policyGateAccess(for result: EvaluationResult) -> PolicyGateAccess {
        if case .deny = result.boundReview {
            return .skip
        }
        return .consider
    }

    /// Pin half: secrets, builtin.action, unwrap-limited analysis, protected-path.
    /// `mandatoryHuman` is Ask/spend, not this pin, unless analysis is already
    /// unwrap-limited or protected-path.
    public static func isPinned(_ result: EvaluationResult) -> Bool {
        if result.analysis.innermost == .unwrapLimited {
            return true
        }
        if case .protectedPath? = result.analysis.filesystemAction?.primaryTarget?.scope {
            return true
        }
        if case .mandatoryHuman = result.boundReview {
            return false
        }
        if case .deny(let deny) = result.decision, isPinnedPack(deny) {
            return true
        }
        return false
    }

    /// Yes for an unpinned deny with cwd and a nonempty matching view.
    public static func isUnlockable(result: EvaluationResult, cwd: WorkingDirectory?) -> Bool {
        guard case .deny = result.decision else { return false }
        guard isPinned(result) == false else { return false }
        guard cwd != nil else { return false }
        guard result.matchingView.isEmpty == false else { return false }
        return true
    }

    /// After apply stayed deny. Not peek. Not Ask. Host-free.
    public static func shouldMintUnlock(result: EvaluationResult, cwd: WorkingDirectory?) -> Bool {
        if case .deny = result.boundReview { return false }
        return isUnlockable(result: result, cwd: cwd)
    }

    public static func project(
        host: HookHost,
        live: LiveEvaluation,
        cwd: WorkingDirectory?,
        continuation: ApprovalContinuation = .hostNative
    ) -> HookAuthorization {
        let profile = HostNativeAsk.profile(for: host)
        switch live.bound {
        case .allow:
            switch live.decision {
            case .allow:
                return .allow
            case .deny(let deny):
                return .denyPinned(deny)
            case .indeterminate:
                return .denyPinned(HostNativeAsk.leftoverAskDeny)
            }
        case .deny(let deny):
            guard isUnlockable(result: live.result, cwd: cwd) else {
                return .denyPinned(deny)
            }
            return pause(
                host: host,
                continuation: continuation,
                ifNoPause: profile.unlockableIfNoPause,
                deny: deny
            )
        case .mandatoryHuman(let deny):
            switch live.decision {
            case .indeterminate:
                return .denyPinned(deny)
            case .allow, .deny:
                return pauseIfSpendable(
                    host: host,
                    continuation: continuation,
                    cwd: cwd,
                    matchingView: live.matchingView,
                    ifNoPause: profile.grayAreaIfNoPause,
                    deny: deny
                )
            }
        }
    }

    public static func project(
        host: HookHost,
        result: EvaluationResult,
        cwd: WorkingDirectory?,
        bound: BoundReview? = nil,
        continuation: ApprovalContinuation = .hostNative
    ) -> HookAuthorization {
        let live = LiveEvaluation(
            outcome: result.outcome,
            matchingView: result.matchingView,
            analysis: result.analysis,
            bound: bound ?? BoundReview.packProjected(from: result)
        )
        return project(host: host, live: live, cwd: cwd, continuation: continuation)
    }

    public var verdict: HostAskVerdict {
        switch self {
        case .allow:
            return .allow
        case .denyPinned, .denyUnlockable:
            return .deny
        case .ask(let continuation):
            return .ask(continuation)
        }
    }

    public var shouldMintUnlock: Bool {
        if case .denyUnlockable = self {
            return true
        }
        return false
    }

    public var shouldRecordPending: Bool {
        if case .ask = self {
            return true
        }
        return false
    }

    private static func isPinnedPack(_ deny: Deny) -> Bool {
        deny.ruleID.pack == .coreSecrets
            || deny.ruleID.pack == ActionPolicyEngine.Builtin.pack
    }

    private static func pauseIfSpendable(
        host: HookHost,
        continuation: ApprovalContinuation,
        cwd: WorkingDirectory?,
        matchingView: MatchingView,
        ifNoPause: HostNoPauseFallback,
        deny: Deny
    ) -> HookAuthorization {
        guard cwd != nil, matchingView.isEmpty == false else {
            return .denyPinned(deny)
        }
        return pause(
            host: host,
            continuation: continuation,
            ifNoPause: ifNoPause,
            deny: deny
        )
    }

    private static func pause(
        host: HookHost,
        continuation: ApprovalContinuation,
        ifNoPause: HostNoPauseFallback,
        deny: Deny
    ) -> HookAuthorization {
        switch (HostNativeAsk.profile(for: host).pause, continuation) {
        case (.spendFirst, .hostNative):
            return .ask(.hostNative)
        default:
            switch ifNoPause {
            case .allow:
                return .allow
            case .deny:
                return .denyUnlockable(deny)
            }
        }
    }
}
