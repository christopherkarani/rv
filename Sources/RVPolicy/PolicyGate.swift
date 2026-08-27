import Foundation
import RVDomain

public enum PolicyOverride: Equatable, Sendable {
    case none
    case allowlist
    case allowOnce
}

public struct PolicyDecision: Equatable, Sendable {
    public var result: EvaluationResult
    public var override: PolicyOverride

    public init(result: EvaluationResult, override: PolicyOverride) {
        self.result = result
        self.override = override
    }
}

public enum PolicyGate {
    /// Total override order. No store, clock, or filesystem.
    public static func decide(
        _ result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot,
        grant: GrantPresence,
        now: Date
    ) -> PolicyDecision {
        switch result.decision {
        case .allow:
            return PolicyDecision(result: result, override: .none)
        case .indeterminate:
            // Miss policy: never allow because evaluation did not finish.
            return PolicyDecision(result: result, override: .none)
        case .deny(let deny):
            if RulePinning.blocksAllowOverride(deny) {
                return PolicyDecision(result: result, override: .none)
            }
            if allowlist.matches(
                ruleID: deny.ruleID,
                matchingView: result.matchingView,
                now: now
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
                return PolicyDecision(result: result, override: .none)
            }
        }
    }

    /// Spends a matching grant. Hook / `rvd` / in-process fallback.
    public static func apply(
        _ result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot = .empty,
        store: AllowOnceStore,
        now: Date
    ) async -> PolicyDecision {
        let withoutGrant = decide(
            result,
            cwd: cwd,
            allowlist: allowlist,
            grant: .none,
            now: now
        )
        guard let cwd = honorCwd(result, cwd: cwd, withoutGrant: withoutGrant) else {
            return withoutGrant
        }
        switch await store.consume(
            matchingView: result.matchingView,
            cwd: cwd,
            now: now
        ) {
        case .consumed:
            return decide(
                result,
                cwd: cwd,
                allowlist: allowlist,
                grant: .pending,
                now: now
            )
        case .notFound, .alreadyConsumed, .expired, .unavailable:
            return withoutGrant
        }
    }

    /// Host Allow once: plant and spend this turn. Fail-closed. Indeterminate never spends.
    public static func spendHostAllowOnce(
        _ result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot = .empty,
        store: AllowOnceStore,
        now: Date
    ) async -> PolicyDecision {
        switch result.decision {
        case .allow:
            return PolicyDecision(result: result, override: .none)
        case .indeterminate:
            return PolicyDecision(result: result, override: .none)
        case .deny:
            let withoutGrant = decide(
                result,
                cwd: cwd,
                allowlist: allowlist,
                grant: .none,
                now: now
            )
            if withoutGrant.override == .allowlist {
                return withoutGrant
            }
            switch await HostGrantWriter.plantAndSpend(
                matchingView: result.matchingView,
                cwd: cwd,
                store: store,
                now: now
            ) {
            case .spent:
                return decide(
                    result,
                    cwd: cwd,
                    allowlist: allowlist,
                    grant: .pending,
                    now: now
                )
            case .rejected:
                return withoutGrant
            }
        }
    }

    /// Shows a matching grant / allowlist without spending it. TTY `test` / `explain`.
    public static func peek(
        _ result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot = .empty,
        store: AllowOnceStore,
        now: Date
    ) async -> PolicyDecision {
        let withoutGrant = decide(
            result,
            cwd: cwd,
            allowlist: allowlist,
            grant: .none,
            now: now
        )
        guard let cwd = honorCwd(result, cwd: cwd, withoutGrant: withoutGrant) else {
            return withoutGrant
        }
        let grant: GrantPresence = await store.hasGrant(
            matchingView: result.matchingView,
            cwd: cwd,
            now: now
        ) ? .pending : .none
        return decide(
            result,
            cwd: cwd,
            allowlist: allowlist,
            grant: grant,
            now: now
        )
    }

    /// Consume / hasGrant only when decide would still need a pending grant.
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
                matchingView: result.matchingView
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
