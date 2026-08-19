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
    public static func apply(
        _ result: EvaluationResult,
        cwd: String,
        store: AllowOnceStore,
        now: Date,
        consume: Bool = true
    ) async -> PolicyDecision {
        switch result.decision {
        case .allow, .indeterminate:
            return PolicyDecision(result: result, override: .none)
        case .deny:
            guard cwd.isEmpty == false, result.matchingView.isEmpty == false else {
                return PolicyDecision(result: result, override: .none)
            }
            if consume == false {
                let hit = await store.hasGrant(
                    matchingView: result.matchingView,
                    cwd: cwd,
                    now: now
                )
                guard hit else {
                    return PolicyDecision(result: result, override: .none)
                }
                var allowed = result
                allowed.decision = .allow
                return PolicyDecision(result: allowed, override: .allowOnce)
            }
            switch await store.consume(
                matchingView: result.matchingView,
                cwd: cwd,
                now: now
            ) {
            case .consumed:
                var allowed = result
                allowed.decision = .allow
                return PolicyDecision(result: allowed, override: .allowOnce)
            case .notFound, .alreadyConsumed, .expired:
                return PolicyDecision(result: result, override: .none)
            }
        }
    }
}
