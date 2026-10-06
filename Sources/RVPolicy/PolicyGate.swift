import Foundation
import RVDomain

public enum PolicyOverride: Equatable, Sendable {
    case none
    case allowlist
    case allowOnce
    case rebaseRecovery
    /// Balanced profile only: contained generated-output delete.
    case containedReversible
}

public struct PolicyDecision: Equatable, Sendable {
    public var result: EvaluationResult
    public var override: PolicyOverride

    public init(result: EvaluationResult, override: PolicyOverride) {
        self.result = result
        self.override = override
    }
}

/// Chooses allowlist, allow-once, or rebase-recovery overrides for an evaluation result.
public enum PolicyGate {
    /// Total override order. No store, clock, or filesystem.
    ///
    /// `safety` selects the coding profile: `.normal` is
    /// CodingAgentBalanced (contained generated-output deletes auto-allow);
    /// `.strict` disables the profile override. Default is strict so
    /// callers opt into the balanced allowance explicitly.
    public static func decision(
        for result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot,
        grant: GrantPresence,
        now: Date,
        rebaseInProgress: Bool = false,
        safety: SafetyLevel = .strict,
        maskedSegments: [String]? = nil
    ) -> PolicyDecision {
        switch result.decision {
        case .allow:
            return PolicyDecision(result: result, override: .none)
        case .indeterminate:
            // Miss policy: never allow because evaluation did not finish.
            return PolicyDecision(result: result, override: .none)
        case .deny(let deny):
            if rebaseInProgress, RebaseRecovery.isEligible(result: result) {
                return allowDecision(result, override: .rebaseRecovery)
            }
            if RulePinning.blocksAllowOverride(result) {
                return PolicyDecision(result: result, override: .none)
            }
            if allowlist.matches(
                ruleID: deny.ruleID,
                matchingView: result.matchingView,
                now: now,
                maskedSegments: maskedSegments
            ) {
                return allowDecision(result, override: .allowlist)
            }
            guard cwd != nil, result.matchingView.isEmpty == false else {
                return PolicyDecision(result: result, override: .none)
            }
            switch grant {
            case .pending:
                return allowDecision(result, override: .allowOnce)
            case .none:
                if safety == .normal, ContainedReversibleDelete.permits(result) {
                    return allowDecision(result, override: .containedReversible)
                }
                return PolicyDecision(result: result, override: .none)
            }
        }
    }

    /// Spends a matching grant. Hook / `rvd` / in-process fallback.
    /// Step 8B.1: spends ONLY service-held memory grants. The allow-once
    /// file is a projection and is never consulted here (B-F1/B-F3).
    /// Pinned rules deny regardless of grants, so a pinned result returns
    /// before consuming: spending a grant the final decision ignores
    /// would burn single-use authority for nothing.
    public static func consumingGrant(
        for result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot = .empty,
        grants: EphemeralAllowOnceTable,
        now: Date,
        rebaseInProgress: Bool = false,
        safety: SafetyLevel = .strict,
        maskedSegments: [String]? = nil
    ) async -> PolicyDecision {
        let withoutGrant = decision(
            for: result,
            cwd: cwd,
            allowlist: allowlist,
            grant: .none,
            now: now,
            rebaseInProgress: rebaseInProgress,
            safety: safety,
            maskedSegments: maskedSegments
        )
        if RulePinning.blocksAllowOverride(result) {
            return withoutGrant
        }
        guard let cwd = honorCwd(result, cwd: cwd, withoutGrant: withoutGrant) else {
            return withoutGrant
        }
        guard await grants.consume(
            matchingView: result.matchingView,
            cwd: cwd,
            now: now,
            maskedSegments: maskedSegments
        ) else {
            return withoutGrant
        }
        return decision(
            for: result,
            cwd: cwd,
            allowlist: allowlist,
            grant: .pending,
            now: now,
            rebaseInProgress: rebaseInProgress,
            safety: safety,
            maskedSegments: maskedSegments
        )
    }

    /// Shows a matching grant / allowlist without spending it. TTY `test` / `explain`.
    /// Step 8B.1: consults ONLY service-held memory grants, never the file.
    public static func preview(
        for result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot = .empty,
        grants: EphemeralAllowOnceTable,
        now: Date,
        rebaseInProgress: Bool = false,
        safety: SafetyLevel = .strict,
        maskedSegments: [String]? = nil
    ) async -> PolicyDecision {
        let withoutGrant = decision(
            for: result,
            cwd: cwd,
            allowlist: allowlist,
            grant: .none,
            now: now,
            rebaseInProgress: rebaseInProgress,
            safety: safety,
            maskedSegments: maskedSegments
        )
        guard let cwd = honorCwd(result, cwd: cwd, withoutGrant: withoutGrant) else {
            return withoutGrant
        }
        let grant: GrantPresence = await grants.hasGrant(
            matchingView: result.matchingView,
            cwd: cwd,
            now: now,
            maskedSegments: maskedSegments
        ) ? .pending : .none
        return decision(
            for: result,
            cwd: cwd,
            allowlist: allowlist,
            grant: grant,
            now: now,
            rebaseInProgress: rebaseInProgress,
            safety: safety,
            maskedSegments: maskedSegments
        )
    }

    /// Consume / hasGrant only when decision would still need a pending grant.
    private static func honorCwd(
        _ result: EvaluationResult,
        cwd: WorkingDirectory?,
        withoutGrant: PolicyDecision
    ) -> WorkingDirectory? {
        guard
            withoutGrant.override == .none,
            case .deny = result.decision,
            let cwd,
            result.matchingView.isEmpty == false
        else {
            return nil
        }
        return cwd
    }

    private static func allowDecision(
        _ result: EvaluationResult,
        override: PolicyOverride
    ) -> PolicyDecision {
        PolicyDecision(
            result: EvaluationResult(
                outcome: allowedOutcome(result.outcome),
                matchingView: result.matchingView,
                analysis: result.analysis
            ),
            override: override
        )
    }

    /// Typed override transition: a deny becomes its allow-equivalent with the
    /// hit structure intact; every other outcome passes through unchanged.
    private static func allowedOutcome(_ outcome: EvaluationOutcome) -> EvaluationOutcome {
        switch outcome {
        case .deny(_, let match):
            guard let match else { return .plain }
            return .hit(match, safe: nil)
        case .quickRejected, .plain, .safeOnly, .hit, .indeterminate:
            return outcome
        }
    }
}
