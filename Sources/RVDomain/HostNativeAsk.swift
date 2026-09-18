/// Whether a host may pause for Ask because a same-turn spend callback exists.
public enum HostPause: Sendable, Equatable {
    /// Host confirm or resolution, then PolicyGate spend, then allow.
    /// Pi / OpenCode / Claude / Hermes / OpenClaw this slice.
    /// Claude leftover-ask-as-permit is official `permissionDecision: "ask"` JSON,
    /// not this case. OpenClaw leftover-ask-as-permit is returning
    /// `requireApproval` (host Allow runs exec). Spend-first still must not
    /// emit those leftover keys.
    case spendFirst
    /// Host has a pause API that would run the tool without a PolicyGate spend.
    /// Codex/Cursor leftover `ask`. Do not emit it.
    case leftoverAskForbidden
    /// No pause RV will use. Grok this slice (native `decision: ask` is unused).
    case noPause
}

/// Wire when the host cannot pause. Never `.ask`.
public enum HostNoPauseFallback: Sendable, Equatable {
    case allow
    case deny

    public var verdict: HostAskVerdict {
        switch self {
        case .allow: .allow
        case .deny: .deny
        }
    }
}

/// Per-host Ask table. Pause is independent of the no-pause fallbacks.
public struct HostAskProfile: Sendable, Equatable {
    public var pause: HostPause
    public var grayAreaIfNoPause: HostNoPauseFallback
    public var unlockableIfNoPause: HostNoPauseFallback

    public init(
        pause: HostPause,
        grayAreaIfNoPause: HostNoPauseFallback,
        unlockableIfNoPause: HostNoPauseFallback
    ) {
        self.pause = pause
        self.grayAreaIfNoPause = grayAreaIfNoPause
        self.unlockableIfNoPause = unlockableIfNoPause
    }

    /// Confirm-then-spend. Fallbacks apply only if the continuation cannot pause.
    public static let spendFirst = HostAskProfile(
        pause: .spendFirst,
        grayAreaIfNoPause: .allow,
        unlockableIfNoPause: .deny
    )

    /// No pause API RV will use. Gray-area runs; unlockable pack deny stays deny.
    public static let noPause = HostAskProfile(
        pause: .noPause,
        grayAreaIfNoPause: .allow,
        unlockableIfNoPause: .deny
    )

    /// Pause API exists and must not be called. Same fallbacks as `noPause`.
    public static let leftoverAskForbidden = HostAskProfile(
        pause: .leftoverAskForbidden,
        grayAreaIfNoPause: .allow,
        unlockableIfNoPause: .deny
    )
}

/// Product Ask on the hook door. Not a `Decision` case.
public enum HostAskVerdict: Sendable, Equatable {
    case allow
    case deny
    case ask(ApprovalContinuation)
}

/// Pack-door verdict. Ask is uninhabited; product Ask is `BoundReview`.
public enum PackDoorVerdict: Sendable, Equatable {
    case allow
    case deny
}

/// Resolution after a human Allow once / Deny on a host-native continuation.
public enum HostAskBridgeResolution: Sendable, Equatable {
    /// Caller must plant+spend via PolicyGate, then allow only if that spend succeeds.
    case spendThenAllow
    case deny
    case denyOrTTY
}

/// Service-edge protocol. Allow once / Deny resolve through PolicyGate, not a second ledger.
public protocol ApprovalBridge: Sendable {
    func resolve(
        host: HookHost,
        continuation: ApprovalContinuation,
        decision: ApprovalDecision
    ) -> HostAskBridgeResolution
}

/// Shared `ApprovalContinuation.hostNative` bridge. Pure; no store I/O.
public struct HostNativeApprovalBridge: ApprovalBridge {
    public init() {}

    public func resolve(
        host: HookHost,
        continuation: ApprovalContinuation,
        decision: ApprovalDecision
    ) -> HostAskBridgeResolution {
        switch decision {
        case .deny, .createRule:
            return .deny
        case .allowOnce:
            switch (continuation, HostNativeAsk.profile(for: host).pause) {
            case (.hostNative, .spendFirst):
                return .spendThenAllow
            default:
                return .denyOrTTY
            }
        }
    }
}

/// Host-native Ask mapping. Leftover unused ask is never a permit.
public enum HostNativeAsk {
    public static let leftoverAskDeny = Deny(
        ruleID: RuleID(pack: ActionPolicyEngine.Builtin.pack, pattern: "leftover-ask"),
        reason: "Ask is not a permit."
    )

    public static func profile(for host: HookHost) -> HostAskProfile {
        switch host {
        case .pi, .opencode, .claude, .hermes, .openclaw:
            return .spendFirst
        case .grok:
            return .noPause
        case .codex, .cursor:
            return .leftoverAskForbidden
        }
    }

    /// Pack / evaluate `Decision` on the hook door. Cannot Ask.
    /// Product Ask is `hostAskVerdict(host:result:cwd:bound:)`.
    public static func packDoorVerdict(for decision: Decision) -> PackDoorVerdict {
        switch decision {
        case .allow:
            return .allow
        case .indeterminate, .deny:
            return .deny
        }
    }

    /// Product Ask on the live hook door. Pause only when a spend-first host
    /// could spend: Unlockable deny or `mandatoryHuman`. On a host that cannot
    /// pause, `mandatoryHuman` uses `grayAreaIfNoPause` (quiet allow today).
    /// Unlockable pack deny uses `unlockableIfNoPause` (deny today). Secret-path,
    /// builtin hard deny, unwrap-limited, protected-path, incomplete evaluate,
    /// missing cwd, and empty matching view stay deny.
    public static func hostAskVerdict(
        host: HookHost,
        result: EvaluationResult,
        cwd: WorkingDirectory?,
        bound: BoundReview,
        continuation: ApprovalContinuation = .hostNative
    ) -> HostAskVerdict {
        HookAuthorization.project(
            host: host,
            result: result,
            cwd: cwd,
            bound: bound,
            continuation: continuation
        ).verdict
    }

    /// Extra / desktop wait. Same eligibility as spend-first Ask. Deny-or-TTY
    /// hosts already allowed `mandatoryHuman` on the wire; unlockable pack deny
    /// still blocks there.
    public static func recordsPending(
        result: EvaluationResult,
        cwd: WorkingDirectory?,
        bound: BoundReview
    ) -> Bool {
        switch bound {
        case .allow:
            return false
        case .deny:
            return HookAuthorization.isUnlockable(result: result, cwd: cwd)
        case .mandatoryHuman:
            return cwd != nil && result.matchingView.isEmpty == false
        }
    }

    /// Projects hard policy onto the hook-live review boundary.
    /// Uncovered actions remain quiet on the hook door until typed effects are
    /// available; shadow review owns the separate review-eligible projection.
    public static func hookBound(_ decision: HardPolicyDecision) -> BoundReview {
        switch decision {
        case .hardAllow:
            return .allow
        case .hardDeny(let deny):
            return .deny(deny)
        case .mandatoryHuman(let deny):
            return .mandatoryHuman(deny)
        case .reviewEligible:
            return .allow
        }
    }

    /// Evaluates a proposed action with the pack result as its fallback, then
    /// projects that hard decision onto the hook-live review boundary.
    public static func hookBound(
        result: EvaluationResult,
        action: ProposedAction,
        context: ReviewContext
    ) -> BoundReview {
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: context,
            policy: EffectiveActionPolicy(packFallback: PackFallback(result))
        )
        return hookBound(verdict.decision)
    }

    /// A leftover unused ask token is never a permit.
    public static let leftoverAskIsPermit = false

}
