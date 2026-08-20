import Foundation
import RVDomain

public enum PolicyOverride: Equatable, Sendable {
    case none
    case allowOnce
}

/// Engine evaluation plus an optional policy overlay.
///
/// `engine` stays the Evaluate-session output. Honor does not rewrite it in place —
/// callers that need the post-gate Decision read `effective`.
public struct PolicyDecision: Equatable, Sendable {
    public let engine: EvaluationResult
    public let override: PolicyOverride

    public init(engine: EvaluationResult, override: PolicyOverride) {
        self.engine = engine
        self.override = override
    }

    /// Decision after the Policy gate (allow-once flips a deny to allow).
    public var effective: EvaluationResult {
        switch override {
        case .none:
            return engine
        case .allowOnce:
            var allowed = engine
            allowed.decision = .allow
            return allowed
        }
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
            return PolicyDecision(engine: result, override: .none)
        }
        switch await store.consume(
            matchingView: granted.result.matchingView,
            cwd: granted.cwd,
            now: now
        ) {
        case .consumed:
            return PolicyDecision(engine: granted.result, override: .allowOnce)
        case .notFound, .alreadyConsumed, .expired, .unavailable:
            return PolicyDecision(engine: result, override: .none)
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
            return PolicyDecision(engine: result, override: .none)
        }
        let hit = await store.hasGrant(
            matchingView: granted.result.matchingView,
            cwd: granted.cwd,
            now: now
        )
        guard hit else {
            return PolicyDecision(engine: result, override: .none)
        }
        return PolicyDecision(engine: granted.result, override: .allowOnce)
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
}
