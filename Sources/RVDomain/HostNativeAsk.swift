/// Whether a host may pause for Ask because a same-turn spend callback exists.
public enum HostAskCapability: Sendable, Equatable {
    /// Pi / OpenCode this slice: host confirm or resolution, then PolicyGate spend, then allow.
    case spendFirst
    /// Claude official `permissionDecision: "ask"` is leftover-ask-as-permit.
    /// Grok / OpenClaw / Hermes: deny or TTY. No first-call Allow.
    case denyOrTTY
}

/// Product Ask on the hook door. Not a `Decision` case.
public enum HostAskVerdict: Sendable, Equatable {
    case allow
    case deny
    case ask(ApprovalContinuation)
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
            switch (continuation, HostNativeAsk.capability(for: host)) {
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
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "leftover-ask"),
        reason: "Ask is not a permit."
    )

    public static func capability(for host: HookHost) -> HostAskCapability {
        switch host {
        case .pi, .opencode:
            return .spendFirst
        case .grok, .claude, .openclaw, .hermes:
            return .denyOrTTY
        }
    }

    /// Pack / evaluate `Decision` on the hook door. Pack deny stays deny here;
    /// product Ask is `BoundReview.mandatoryHuman`.
    public static func verdict(
        host _: HookHost,
        decision: Decision
    ) -> HostAskVerdict {
        switch decision {
        case .allow:
            return .allow
        case .indeterminate, .deny:
            return .deny
        }
    }

    /// Stop collapsing `mandatoryHuman` to deny before a spend-first host.
    public static func verdict(
        host: HookHost,
        bound: BoundReview,
        continuation: ApprovalContinuation = .hostNative
    ) -> HostAskVerdict {
        switch bound {
        case .allow:
            return .allow
        case .deny:
            return .deny
        case .mandatoryHuman:
            return pauseIfPossible(host: host, continuation: continuation)
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
    public static func leftoverAskIsPermit(_ unused: String) -> Bool {
        _ = unused
        return false
    }

    private static func pauseIfPossible(
        host: HookHost,
        continuation: ApprovalContinuation
    ) -> HostAskVerdict {
        switch (capability(for: host), continuation) {
        case (.spendFirst, .hostNative):
            return .ask(.hostNative)
        default:
            return .deny
        }
    }
}
