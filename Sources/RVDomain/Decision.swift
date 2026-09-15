/// Pack-door deny payload. `Decision` is never Ask.
public struct Deny: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var reason: String

    public init(ruleID: RuleID, reason: String) {
        self.ruleID = ruleID
        self.reason = reason
    }
}

/// Why evaluate could not finish. `Decision` is never Ask.
public enum IndeterminateReason: String, Sendable, Equatable, Codable {
    case budgetExhausted
    case commandTooLarge
    case corePacksUnavailable
}

/// Pack-door evaluate result: allow, deny, or indeterminate. Never Ask.
public enum Decision: Sendable, Equatable {
    case allow
    case deny(Deny)
    case indeterminate(IndeterminateReason)
}
