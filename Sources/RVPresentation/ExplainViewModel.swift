import RVDomain

public struct ExplainStep: Equatable, Sendable {
    public var name: String
    public var outcome: String

    public init(name: String, outcome: String) {
        self.name = name
        self.outcome = outcome
    }
}

public struct ExplainViewModel: Equatable, Sendable {
    public var command: ShellCommand
    public var normalized: String
    public var decision: Decision
    public var packID: PackID?
    public var ruleID: RuleID?
    public var fact: String
    public var nextAction: String?
    public var steps: [ExplainStep]

    public init(
        command: ShellCommand,
        normalized: String,
        decision: Decision,
        packID: PackID?,
        ruleID: RuleID?,
        fact: String,
        nextAction: String?,
        steps: [ExplainStep]
    ) {
        self.command = command
        self.normalized = normalized
        self.decision = decision
        self.packID = packID
        self.ruleID = ruleID
        self.fact = fact
        self.nextAction = nextAction
        self.steps = steps
    }
}

public func explainViewModel(
    from result: EvaluationResult,
    command: ShellCommand,
    normalized: String? = nil
) -> ExplainViewModel {
    let fact: String
    let next: String?
    switch result.decision {
    case .allow:
        fact = "allow"
        next = nil
    case .deny(let deny):
        fact = factSentence(from: deny.reason)
        next = denyNextAction
    case .indeterminate:
        fact = incompleteEvalSentence
        next = nil
    }

    let packID: PackID?
    let ruleID: RuleID?
    if case .deny(let deny) = result.decision {
        packID = deny.ruleID.pack
        ruleID = deny.ruleID
    } else {
        packID = result.matched?.packID
        ruleID = result.matched?.ruleID
    }

    return ExplainViewModel(
        command: command,
        normalized: normalized ?? command.rawValue,
        decision: result.decision,
        packID: packID,
        ruleID: ruleID,
        fact: fact,
        nextAction: next,
        steps: explainSteps(from: result)
    )
}

public func explainSteps(from result: EvaluationResult) -> [ExplainStep] {
    var steps = [ExplainStep(name: "normalize", outcome: "prepared")]
    if case .indeterminate = result.decision {
        steps.append(ExplainStep(name: "default", outcome: "incomplete"))
        return steps
    }
    if result.quickRejected {
        steps.append(ExplainStep(name: "quick-reject", outcome: "skipped"))
        steps.append(ExplainStep(name: "default", outcome: "allow"))
        return steps
    }
    steps.append(ExplainStep(name: "quick-reject", outcome: "scanned"))
    if let safe = result.matchedSafe, result.matched == nil {
        steps.append(ExplainStep(name: "safe", outcome: displayRuleID(RuleID(pack: safe.pack, pattern: safe.name))))
        steps.append(ExplainStep(name: "default", outcome: "allow"))
        return steps
    }
    steps.append(ExplainStep(name: "safe", outcome: "none"))
    if let match = result.matched {
        steps.append(ExplainStep(name: "destructive", outcome: displayRuleID(match.ruleID)))
        if result.decision == .allow {
            steps.append(ExplainStep(name: "default", outcome: "allow"))
        }
        return steps
    }
    steps.append(ExplainStep(name: "destructive", outcome: "none"))
    steps.append(ExplainStep(name: "default", outcome: "allow"))
    return steps
}
