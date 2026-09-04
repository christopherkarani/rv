/// Compiled matcher. English is not a field; the hook matches this form.
public struct TypedRule: Sendable, Equatable, Codable {
    public var id: RuleID
    public var predicate: PolicyPredicate
    public var verdict: TypedRuleVerdict
    public var origin: TypedRuleOrigin

    public init(
        id: RuleID,
        predicate: PolicyPredicate,
        verdict: TypedRuleVerdict,
        origin: TypedRuleOrigin
    ) {
        self.id = id
        self.predicate = predicate
        self.verdict = verdict
        self.origin = origin
    }
}

public enum TypedRuleVerdict: String, Sendable, Equatable, Codable {
    case allow
    case ask
    case deny
}

public enum TypedRuleOrigin: String, Sendable, Equatable, Codable {
    case builtin
    case machine
    case repo
}
