import RVDomain

/// A typed rule that also matches an explained command but did not decide
/// it: a pack deny returns before typed rules run, so without this row
/// `rv explain` never showed the person's own rule.
public struct ExplainAlsoMatch: Equatable, Sendable, Encodable {
    /// Where the rule lives. A ceiling rule is the owner's, not the person's.
    public enum Source: String, Sendable, Encodable {
        case machine
        case repo
        case ceiling
    }

    public var ruleID: RuleID
    public var source: Source
    public var verdict: TypedRuleVerdict

    public init(ruleID: RuleID, source: Source, verdict: TypedRuleVerdict) {
        self.ruleID = ruleID
        self.source = source
        self.verdict = verdict
    }

    /// Row label in the explain tree.
    public var label: String {
        source == .ceiling ? "Ceiling" : "Your rule"
    }

    /// `typed.git:force-push-main · this repo (.rv/policy.toml) · deny`
    public var display: String {
        var text = "\(DisplayedText.field(ruleID.rawValue)) · \(place) · \(verdict.rawValue)"
        if verdict == .allow {
            text += " (allow is restrict-only: it never lets through what rv or a pack stops)"
        }
        return text
    }

    private var place: String {
        switch source {
        case .machine: return "this machine (~/.config/rv/policy.toml)"
        case .repo: return "this repo (.rv/policy.toml)"
        case .ceiling: return "owner ceiling (~/.config/rv/ceiling.toml)"
        }
    }

    enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id"
        case source
        case verdict
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ruleID.rawValue, forKey: .ruleID)
        try container.encode(source, forKey: .source)
        try container.encode(verdict.rawValue, forKey: .verdict)
    }
}
