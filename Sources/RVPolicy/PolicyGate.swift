import Foundation
import RVDomain

public struct PolicyDecision: Equatable, Sendable {
    public var result: EvaluationResult
    public var override: PolicyOverride

    public init(result: EvaluationResult, override: PolicyOverride) {
        self.result = result
        self.override = override
    }
}

public enum PolicyGate {
    /// Spends a matching grant. Hook / `rvd` / in-process fallback.
    public static func apply(
        _ result: EvaluationResult,
        cwd: String?,
        allowlist: AllowlistSnapshot = .empty,
        store: AllowOnceStore,
        now: Date
    ) async -> PolicyDecision {
        switch result.decision {
        case .allow:
            return PolicyDecision(result: result, override: .none)
        case .indeterminate:
            // Miss policy: never allow because evaluation did not finish.
            // Hook layer maps indeterminate → deny voice; do not consume grants.
            return PolicyDecision(result: result, override: .none)
        case .deny(let deny):
            if allowlist.matches(
                ruleID: deny.ruleID,
                matchingView: result.matchingView,
                now: now
            ) {
                return allowDecision(result, override: .allowlist)
            }
            guard let cwd, cwd.isEmpty == false, result.matchingView.isEmpty == false else {
                return PolicyDecision(result: result, override: .none)
            }
            switch await store.consume(
                matchingView: result.matchingView,
                cwd: cwd,
                now: now
            ) {
            case .consumed:
                return allowDecision(result, override: .allowOnce)
            case .notFound, .alreadyConsumed, .expired, .unavailable:
                return PolicyDecision(result: result, override: .none)
            }
        }
    }

    /// Shows a matching grant / allowlist without spending it. TTY `test` / `explain`.
    public static func peek(
        _ result: EvaluationResult,
        cwd: String?,
        allowlist: AllowlistSnapshot = .empty,
        store: AllowOnceStore,
        now: Date
    ) async -> PolicyDecision {
        switch result.decision {
        case .allow:
            return PolicyDecision(result: result, override: .none)
        case .indeterminate:
            return PolicyDecision(result: result, override: .none)
        case .deny(let deny):
            if allowlist.matches(
                ruleID: deny.ruleID,
                matchingView: result.matchingView,
                now: now
            ) {
                return allowDecision(result, override: .allowlist)
            }
            guard let cwd, cwd.isEmpty == false, result.matchingView.isEmpty == false else {
                return PolicyDecision(result: result, override: .none)
            }
            let hit = await store.hasGrant(
                matchingView: result.matchingView,
                cwd: cwd,
                now: now
            )
            guard hit else {
                return PolicyDecision(result: result, override: .none)
            }
            return allowDecision(result, override: .allowOnce)
        }
    }

    private static func allowDecision(
        _ result: EvaluationResult,
        override: PolicyOverride
    ) -> PolicyDecision {
        var allowed = result
        allowed.decision = .allow
        allowed.policyOverride = override
        return PolicyDecision(result: allowed, override: override)
    }
}
