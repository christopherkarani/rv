import RVDomain

public struct ExplainViewModel: Equatable, Sendable {
    public var command: ShellCommand
    public var normalized: String
    public var decision: Decision
    public var packID: PackID?
    public var ruleID: RuleID?
    public var patternName: String?
    public var severity: Severity?
    public var fact: String
    public var explanation: String?
    public var regex: String?
    public var nextAction: String?
    public var steps: [ExplainStep]
    public var suggestions: [ExplainSuggestion]

    public var heading: String { explainHeading }
    public var decisionWord: String { RVPresentation.decisionWord(decision) }
    public var explainDecisionWord: String { RVPresentation.explainDecisionWord(decision) }
    public var decisionTone: DecisionTone { RVPresentation.decisionTone(decision) }
    public var ruleDisplay: String? { ruleID.map(displayRuleID) }
    public var packDisplay: String? { packID?.rawValue }
    public var severityDisplay: String? { severity?.rawValue }

    public init(
        command: ShellCommand,
        normalized: String,
        decision: Decision,
        packID: PackID?,
        ruleID: RuleID?,
        patternName: String? = nil,
        severity: Severity? = nil,
        fact: String,
        explanation: String? = nil,
        regex: String? = nil,
        nextAction: String?,
        steps: [ExplainStep],
        suggestions: [ExplainSuggestion] = []
    ) {
        self.command = command
        self.normalized = normalized
        self.decision = decision
        self.packID = packID
        self.ruleID = ruleID
        self.patternName = patternName
        self.severity = severity
        self.fact = fact
        self.explanation = explanation
        self.regex = regex
        self.nextAction = nextAction
        self.steps = steps
        self.suggestions = suggestions
    }
}

public func explainViewModel(
    from result: EvaluationResult,
    command: ShellCommand,
    normalized: String? = nil
) -> ExplainViewModel {
    let fact: String
    let next: String?
    let packID: PackID?
    let ruleID: RuleID?
    switch result.decision {
    case .allow:
        fact = "allow"
        next = nil
        packID = result.matched?.packID
        ruleID = result.matched?.ruleID
    case .deny(let deny):
        fact = factSentence(from: deny.reason)
        next = denyNextAction
        packID = deny.ruleID.pack
        ruleID = deny.ruleID
    case .indeterminate:
        fact = incompleteEvalSentence
        next = nil
        packID = result.matched?.packID
        ruleID = result.matched?.ruleID
    }

    return ExplainViewModel(
        command: command,
        normalized: normalized ?? command.rawValue,
        decision: result.decision,
        packID: packID,
        ruleID: ruleID,
        patternName: result.matched?.patternName,
        severity: result.matched?.severity,
        fact: fact,
        explanation: result.matched?.explanation,
        regex: result.matched?.regex,
        nextAction: next,
        steps: explainSteps(from: result),
        suggestions: ruleID.map { suggestions(for: $0) } ?? []
    )
}
