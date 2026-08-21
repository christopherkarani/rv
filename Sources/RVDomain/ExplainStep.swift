/// One stage in the Explain pipeline, including that stage's outcome.
public enum ExplainStep: Equatable, Sendable {
    /// Pipeline stage. `rawValue` is the stable TTY/XPC stage name.
    public enum ID: String, Equatable, Sendable {
        case normalize
        case quickReject = "quick-reject"
        case safe
        case destructive
        case `default`
    }

    /// Quick-reject outcome: `skipped` if it fired; `scanned` if walkers ran.
    public enum Scan: Equatable, Sendable {
        case skipped
        case scanned
    }

    /// Safe or destructive walker result: no match, or the hitting rule.
    public enum Hit: Equatable, Sendable {
        case none
        case rule(RuleID)
    }

    /// Outcome of the default pipeline stage.
    public enum Fallthrough: Equatable, Sendable {
        case allow
        case incomplete
    }

    case normalize
    case quickReject(Scan)
    case safe(Hit)
    case destructive(Hit)
    case `default`(Fallthrough)

    /// Pipeline stage this step occupies.
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
/// Exhaustive switch over EvaluationOutcome. Deny outcomes carry no safe
/// context: `EvaluationOutcome.deny` has no SafeMatch slot and decoding a
/// deny-with-safe frame throws, so the safe stage reports `.none` — the drop
/// is enforced by the type, not silently ignored here. Does not re-run
/// normalize, quick-reject, or the walkers.
public func explainSteps(from result: EvaluationResult) -> [ExplainStep] {
    let prepared = ExplainStep.normalize
    switch result.outcome {
    case .indeterminate:
        return [prepared, .default(.incomplete)]
    case .quickRejected:
        return [prepared, .quickReject(.skipped), .default(.allow)]
    case .plain:
        return [
            prepared,
            .quickReject(.scanned),
            .safe(.none),
            .destructive(.none),
            .default(.allow),
        ]
    case .safeOnly(let safe):
        return [
            prepared,
            .quickReject(.scanned),
            .safe(.rule(safe.ruleID)),
            .default(.allow),
        ]
    case .hit(let match, let safe):
        let safeHit: ExplainStep.Hit = safe.map { .rule($0.ruleID) } ?? .none
        return [
            prepared,
            .quickReject(.scanned),
            .safe(safeHit),
            .destructive(.rule(match.ruleID)),
            .default(.allow),
        ]
    case .deny(let deny, _):
        return [
            prepared,
            .quickReject(.scanned),
            .safe(.none),
            .destructive(.rule(deny.ruleID)),
        ]
    }
}

/// Derived projections of EvaluationResult for assertion-style readers;
/// production consumers pattern-match `outcome` directly. Remaining readers
/// live in out-of-scope test suites: EvaluateOrderTests, CorpusTests,
/// ExplainDispatchTests.
extension EvaluationResult {
    public var matched: RuleMatch? { outcome.matched }
    public var matchedSafe: SafeMatch? { outcome.matchedSafe }
    public var quickRejected: Bool { outcome.quickRejected }
}
