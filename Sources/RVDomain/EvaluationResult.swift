public struct RuleMatch: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var packID: PackID
    public var patternName: String
    public var severity: Severity
    public var reason: String
    public var explanation: String?

    public init(
        ruleID: RuleID,
        packID: PackID,
        patternName: String,
        severity: Severity,
        reason: String,
        explanation: String? = nil
    ) {
        self.ruleID = ruleID
        self.packID = packID
        self.patternName = patternName
        self.severity = severity
        self.reason = reason
        self.explanation = explanation
    }
}

public struct SafeMatch: Sendable, Equatable, Codable {
    public var pack: PackID
    public var name: String

    public init(pack: PackID, name: String) {
        self.pack = pack
        self.name = name
    }
}

public struct EvaluationResult: Sendable, Equatable, Codable {
    public var decision: Decision
    public var matched: RuleMatch?
    public var matchedSafe: SafeMatch?
    public var quickRejected: Bool

    public init(
        decision: Decision,
        matched: RuleMatch? = nil,
        matchedSafe: SafeMatch? = nil,
        quickRejected: Bool = false
    ) {
        self.decision = decision
        self.matched = matched
        self.matchedSafe = matchedSafe
        self.quickRejected = quickRejected
    }
}
