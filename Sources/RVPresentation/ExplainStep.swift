import RVDomain

/// Pipeline stage shown by `rv explain`.
public enum ExplainStage: String, Equatable, Sendable {
    case normalize
    case quickReject = "quick-reject"
    case safe
    case destructive
    case `default`
}

/// One evaluate stage as `rv explain` shows it.
///
/// Each case carries only the outcomes that stage can produce.
public enum ExplainStep: Equatable, Sendable {
    /// Quick-reject ran (`skipped`) or did not fire (`scanned`).
    public enum Scan: Equatable, Sendable {
        case skipped
        case scanned
    }

    /// A walker hit a named rule, or none.
    public enum Hit: Equatable, Sendable {
        case none
        case rule(RuleID)
    }

    /// Terminal default after walkers, or an incomplete eval.
    public enum Fallthrough: Equatable, Sendable {
        case allow
        case incomplete
    }

    case normalize
    case quickReject(Scan)
    case safe(Hit)
    case destructive(Hit)
    case `default`(Fallthrough)

    public var name: ExplainStage {
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

    /// Stage label in the pipeline tree.
    public var label: String { name.rawValue }

    /// Outcome text in the pipeline tree. Normalize is always `prepared`.
    public var displayOutcome: String {
        switch self {
        case .normalize:
            return "prepared"
        case .quickReject(.skipped):
            return "skipped"
        case .quickReject(.scanned):
            return "scanned"
        case .safe(.none), .destructive(.none):
            return "none"
        case .safe(.rule(let ruleID)), .destructive(.rule(let ruleID)):
            return displayRuleID(ruleID)
        case .default(.allow):
            return "allow"
        case .default(.incomplete):
            return "incomplete"
        }
    }
}

/// Projects the evaluate result onto the explain pipeline.
///
/// Switches on `Decision` plus `matched` / `matchedSafe` / `quickRejected` only.
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
            return [
                prepared,
                .quickReject(.scanned),
                .safe(.none),
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
