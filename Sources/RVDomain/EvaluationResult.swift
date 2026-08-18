public struct MatchSpan: Sendable, Equatable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct RuleMatch: Sendable, Equatable {
    public var ruleID: RuleID
    public var packID: PackID
    public var patternName: String
    public var severity: Severity
    public var reason: String
    public var explanation: String?
    public var regex: String?
    public var span: MatchSpan?
    public var matchedText: String?
    public var searchText: String?

    public init(
        ruleID: RuleID,
        packID: PackID,
        patternName: String,
        severity: Severity,
        reason: String,
        explanation: String? = nil,
        regex: String? = nil,
        span: MatchSpan? = nil,
        matchedText: String? = nil,
        searchText: String? = nil
    ) {
        self.ruleID = ruleID
        self.packID = packID
        self.patternName = patternName
        self.severity = severity
        self.reason = reason
        self.explanation = explanation
        self.regex = regex
        self.span = span
        self.matchedText = matchedText
        self.searchText = searchText
    }
}

public struct SafeMatch: Sendable, Equatable {
    public var packID: PackID
    public var patternName: String

    public init(packID: PackID, patternName: String) {
        self.packID = packID
        self.patternName = patternName
    }

    public var ruleID: RuleID {
        RuleID(pack: packID, pattern: patternName)
    }
}

public struct EvaluationResult: Sendable, Equatable {
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
