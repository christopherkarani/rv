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
    /// An inline interpreter/awk/sed program carries spawn, eval, delete,
    /// or secret-read markers and no judge was available to score it.
    case inlineProgramNeedsJudge
    /// An `rv` invocation that would weaken rv; the owner runs it in Terminal.
    case selfProtection
    /// A package-manager runner whose script graph could not be resolved
    /// (untracked cd, workspace run, malformed package.json, ...) and no
    /// judge was available to score it.
    case packageScriptUnresolved
    /// The program or git subcommand a command runs is not statically
    /// known: a same-line shell function, a variable head, a dynamic
    /// `eval`, a command after `source`, or an unknown git subcommand
    /// (an alias or extension defined outside the command line).
    case unresolvedInvocation
}

/// Pack-door evaluate result: allow, deny, or indeterminate. Never Ask.
public enum Decision: Sendable, Equatable {
    case allow
    case deny(Deny)
    case indeterminate(IndeterminateReason)
}
