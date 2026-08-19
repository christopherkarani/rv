import RVDomain

extension ExplainStep {
    /// Stage label in the pipeline tree.
    public var label: String { id.rawValue }

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
