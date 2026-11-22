import RVDomain

/// What one destructive rule offers the person or agent it stops: its
/// stable id, a safer command rv allows, and labelled example commands.
///
/// Pack JSON carries this beside each destructive pattern
/// (`safer_command`, `examples.stop`, `examples.allow`). The engine never
/// reads it: `PackSnapshot` and the pinned evaluate contract are unchanged.
/// Deny rendering and `rv packs test` read it through `PackDocument` or
/// `RuleGuidanceCatalog`.
public struct RuleGuidance: Sendable, Equatable {
    /// `pack:pattern`, the same id a deny carries.
    public var ruleID: RuleID
    /// A command to run instead. Nil when no variant is safe (force-pushing
    /// a shared branch has none: it needs a human). When present, the pack
    /// catalog allows it; `RuleGuidanceTests` fails the build otherwise.
    public var saferCommand: String?
    public var examples: RuleExamples

    public init(ruleID: RuleID, saferCommand: String? = nil, examples: RuleExamples = RuleExamples()) {
        self.ruleID = ruleID
        self.saferCommand = saferCommand
        self.examples = examples
    }
}

/// Commands that prove a rule. `stop` commands make this rule fire with its
/// pack on (critical and high stop the command; medium and low let it run
/// and record the match). `allow` commands are near misses this rule must
/// let through.
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
