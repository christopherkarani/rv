public struct Deny: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var reason: String

    public init(ruleID: RuleID, reason: String) {
        self.ruleID = ruleID
        self.reason = reason
    }
}

public enum IndeterminateReason: String, Sendable, Equatable, Codable {
    case budgetExhausted
    case commandTooLarge
    case corePacksUnavailable
}

public enum Decision: Sendable, Equatable {
    case allow
    case deny(Deny)
    case indeterminate(IndeterminateReason)
}
