/// Transitional shims over EvaluationOutcome for callers not yet migrated to
/// pattern matching. Owned by the outcome-state-machine migration; delete once
/// every consumer reads `outcome` directly.
extension EvaluationResult {
    public var matched: RuleMatch? { outcome.matched }
    public var matchedSafe: SafeMatch? { outcome.matchedSafe }
    public var quickRejected: Bool { outcome.quickRejected }

    public init(
        decision: Decision,
        matched: RuleMatch? = nil,
        matchedSafe: SafeMatch? = nil,
        quickRejected: Bool = false,
        matchingView: MatchingView = MatchingView("")
    ) {
        let composed: EvaluationOutcome
        do {
            composed = try .composing(
                decision: decision,
                matched: matched,
                matchedSafe: matchedSafe,
                quickRejected: quickRejected
            )
        } catch {
            preconditionFailure("invalid legacy EvaluationResult combination: \(error)")
        }
        self.init(outcome: composed, matchingView: matchingView)
    }
}
