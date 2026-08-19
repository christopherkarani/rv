import Foundation
import RVDomain

public enum PolicyOverride: Equatable, Sendable {
    case none
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
    /// Spends a matching grant. Hook / `rvd` / in-process fallback.
    public static func apply(
        _ result: EvaluationResult,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> PolicyDecision {
        guard let granted = grantCandidate(result, cwd: cwd) else {
            return PolicyDecision(result: result, override: .none)
        }
        switch await store.consume(
            matchingView: granted.result.matchingView,
            cwd: granted.cwd,
            now: now
        ) {
        case .consumed:
            return allowOnceDecision(granted.result)
        case .notFound, .alreadyConsumed, .expired, .unavailable:
            return PolicyDecision(result: result, override: .none)
        }
    }

    /// Shows a matching grant without spending it. TTY `test` / `explain`.
    public static func peek(
        _ result: EvaluationResult,
        cwd: String?,
        store: AllowOnceStore,
        now: Date
    ) async -> PolicyDecision {
        guard let granted = grantCandidate(result, cwd: cwd) else {
            return PolicyDecision(result: result, override: .none)
        }
        let hit = await store.hasGrant(
            matchingView: granted.result.matchingView,
            cwd: granted.cwd,
            now: now
        )
        guard hit else {
            return PolicyDecision(result: result, override: .none)
        }
        return allowOnceDecision(granted.result)
    }

    private static func grantCandidate(
        _ result: EvaluationResult,
        cwd: String?
    ) -> (result: EvaluationResult, cwd: String)? {
        switch result.decision {
        case .allow, .indeterminate:
            return nil
        case .deny:
            guard let cwd, cwd.isEmpty == false, result.matchingView.isEmpty == false else {
                return nil
            }
            return (result, cwd)
        }
    }

    private static func allowOnceDecision(_ result: EvaluationResult) -> PolicyDecision {
        var allowed = result
        allowed.decision = .allow
        return PolicyDecision(result: allowed, override: .allowOnce)
    }
}
