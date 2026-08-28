import RVDomain

public struct ExplainSemanticView: Equatable, Sendable {
    public var action: String
    public var scope: String
    public var effect: String?
    public var remote: String?
    public var ref: String?
    public var pathspec: String?

    public init(
        action: String,
        scope: String,
        effect: String? = nil,
        remote: String? = nil,
        ref: String? = nil,
        pathspec: String? = nil
    ) {
        self.action = action
        self.scope = scope
        self.effect = effect
        self.remote = remote
        self.ref = ref
        self.pathspec = pathspec
    }
}

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
    public var semantic: ExplainSemanticView?

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
        suggestions: [ExplainSuggestion] = [],
        semantic: ExplainSemanticView? = nil
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
        self.semantic = semantic
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
    let match: RuleMatch?
    switch result.outcome {
    case .quickRejected, .plain, .safeOnly:
        fact = "allow"
        next = nil
        packID = nil
        ruleID = nil
        match = nil
    case .hit(let hit, _):
        fact = "allow"
        next = nil
        packID = hit.packID
        ruleID = hit.ruleID
        match = hit
    case .deny(let deny, let matched):
        fact = factSentence(from: deny.reason)
        next = denyNextAction
        packID = deny.ruleID.pack
        ruleID = deny.ruleID
        match = matched
    case .indeterminate:
        fact = incompleteEvalSentence
        next = nil
        packID = nil
        ruleID = nil
        match = nil
    }

    return ExplainViewModel(
        command: command,
        normalized: normalized ?? command.rawValue,
        decision: result.decision,
        packID: packID,
        ruleID: ruleID,
        patternName: match?.patternName,
        severity: match?.severity,
        fact: fact,
        explanation: match?.explanation,
        regex: match?.regex,
        nextAction: next,
        steps: explainSteps(from: result),
        suggestions: ruleID.map { suggestions(for: $0) } ?? [],
        semantic: explainSemantic(from: result.analysis)
    )
}

public func explainSemantic(from analysis: SemanticAnalysis) -> ExplainSemanticView? {
    guard case .git(let action) = analysis else { return nil }
    return ExplainSemanticView(
        action: action.explainAction,
        scope: action.explainScope,
        effect: action.explainEffect,
        remote: action.explainRemote,
        ref: action.explainRef,
        pathspec: action.explainPathspec
    )
}
