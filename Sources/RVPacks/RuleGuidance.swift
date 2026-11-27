import RVDomain

/// What one destructive rule offers the person or agent it stops: its
/// stable id, a safer command rv allows or who has to act instead, and
/// labelled example commands.
///
/// Pack JSON carries this beside each destructive pattern
/// (`safer_command`, `who_acts`, `examples.stop`, `examples.allow`). The engine never
/// reads it: `PackSnapshot` and the pinned evaluate contract are unchanged.
/// Deny rendering and `rv packs test` read it through `PackDocument` or
/// `RuleGuidanceCatalog`.
public struct RuleGuidance: Sendable, Equatable {
    /// `pack:pattern`, the same id a deny carries.
    public var ruleID: RuleID
    /// A command to run instead, ready to copy: `<name>` marks an argument
    /// the person fills in (`aws s3 ls s3://<bucket>`). It only reads, lists
    /// or dry-runs, and never prints a secret value. Nil when no variant is
    /// safe (force-pushing a shared branch has none: it needs a human). When
    /// present, the packs and the hook door allow it; `RuleGuidanceTests`
    /// fails the build otherwise.
    public var saferCommand: String?
    /// Who has to act when there is no safer command, in a few words: "you,
    /// in your own terminal", "an admin, in their own terminal". Every
    /// `core.*` rule carries a safer command or this.
    public var whoActs: String?
    public var examples: RuleExamples

    public init(
        ruleID: RuleID,
        saferCommand: String? = nil,
        whoActs: String? = nil,
        examples: RuleExamples = RuleExamples()
    ) {
        self.ruleID = ruleID
        self.saferCommand = saferCommand
        self.whoActs = whoActs
        self.examples = examples
    }
}

/// Commands that prove a rule. `stop` commands make this rule fire with its
/// pack on (critical and high stop the command; medium and low let it run
/// and record the match). `allow` commands are near misses that rv runs
/// with the rule's pack on: no rule fires and the hook door allows them.
public struct RuleExamples: Sendable, Equatable {
    public var stop: [String]
    public var allow: [String]

    public init(stop: [String] = [], allow: [String] = []) {
        self.stop = stop
        self.allow = allow
    }
}

/// Guidance for every rule in a set of packs, looked up by the id a deny
/// carries.
public struct RuleGuidanceCatalog: Sendable, Equatable {
    private var byRuleID: [RuleID: RuleGuidance]

    public init(documents: [PackDocument]) {
        var byRuleID: [RuleID: RuleGuidance] = [:]
        for document in documents {
            for guidance in document.guidance {
                byRuleID[guidance.ruleID] = guidance
            }
        }
        self.byRuleID = byRuleID
    }

    public subscript(ruleID: RuleID) -> RuleGuidance? {
        byRuleID[ruleID]
    }

    public var count: Int { byRuleID.count }
}
