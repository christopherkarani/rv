/// One stage in the Explain pipeline, including that stage's outcome.
public enum ExplainStep: Equatable, Sendable {
    public enum ID: String, Equatable, Sendable {
        case normalize
        case quickReject = "quick-reject"
        case safe
        case destructive
        case `default`
    }

    public enum Scan: Equatable, Sendable {
        case skipped
        case scanned
    }

    public enum Hit: Equatable, Sendable {
        case none
        case rule(RuleID)
    }

    public enum Fallthrough: Equatable, Sendable {
        case allow
        case incomplete
    }

    case normalize
    case quickReject(Scan)
    case safe(Hit)
    case destructive(Hit)
    case `default`(Fallthrough)

    public var id: ID {
        switch self {
        case .normalize:
            return .normalize
        case .quickReject:
            return .quickReject
        case .safe:
            return .safe
        case .destructive:
            return .destructive
        case .default:
            return .default
        }
    }
}

/// Projects an EvaluationResult onto the Explain pipeline.
///
/// Switches on Decision plus matched / matchedSafe / quickRejected only.
/// Does not re-run normalize, quick-reject, or the walkers.
public func explainSteps(from result: EvaluationResult) -> [ExplainStep] {
    let prepared = ExplainStep.normalize
    switch result.decision {
    case .indeterminate:
        return [prepared, .default(.incomplete)]
    case .deny(let deny):
        return [
            prepared,
            .quickReject(.scanned),
            .safe(.none),
            .destructive(.rule(deny.ruleID)),
        ]
    case .allow:
        if result.quickRejected {
            return [prepared, .quickReject(.skipped), .default(.allow)]
        }
        if let safe = result.matchedSafe, result.matched == nil {
            return [
                prepared,
                .quickReject(.scanned),
                .safe(.rule(safe.ruleID)),
                .default(.allow),
            ]
        }
        if let match = result.matched {
            let safe: ExplainStep.Hit = result.matchedSafe.map { .rule($0.ruleID) } ?? .none
            return [
                prepared,
                .quickReject(.scanned),
                .safe(safe),
                .destructive(.rule(match.ruleID)),
                .default(.allow),
            ]
        }
        return [
            prepared,
            .quickReject(.scanned),
            .safe(.none),
            .destructive(.none),
            .default(.allow),
        ]
    }
}
