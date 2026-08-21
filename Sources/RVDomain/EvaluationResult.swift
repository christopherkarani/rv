public struct MatchSpan: Sendable, Equatable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct RuleMatch: Sendable, Equatable, Codable {
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

public struct SafeMatch: Sendable, Equatable, Codable {
    public var packID: PackID
    public var patternName: String

    public init(packID: PackID, patternName: String) {
        self.packID = packID
        self.patternName = patternName
    }

    /// pack:pattern, same construction as `RuleMatch.ruleID`.
    public var ruleID: RuleID {
        RuleID(pack: packID, pattern: patternName)
    }
}

public struct EvaluationResult: Sendable, Equatable {
    public var decision: Decision
    public var matched: RuleMatch?
    public var matchedSafe: SafeMatch?
    public var quickRejected: Bool
    /// T1-normalized command text this result was decided on.
    public var matchingView: MatchingView
    public var policyOverride: PolicyOverride

    public init(
        decision: Decision,
        matched: RuleMatch? = nil,
        matchedSafe: SafeMatch? = nil,
        quickRejected: Bool = false,
        matchingView: MatchingView = MatchingView(""),
        policyOverride: PolicyOverride = .none
    ) {
        self.decision = decision
        self.matched = matched
        self.matchedSafe = matchedSafe
        self.quickRejected = quickRejected
        self.matchingView = matchingView
        self.policyOverride = policyOverride
    }
}

extension EvaluationResult {
    /// Destructive hit that still blocks. Nil on allow, honor, advisory, and indeterminate.
    public var blockingMatch: RuleMatch? {
        guard case .deny = decision else { return nil }
        return matched
    }
}

extension EvaluationResult: Codable {
    enum CodingKeys: String, CodingKey {
        case decision
        case matched
        case matchedSafe
        case quickRejected
        case matchingView
        case policyOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(Decision.self, forKey: .decision)
        matched = try container.decodeIfPresent(RuleMatch.self, forKey: .matched)
        matchedSafe = try container.decodeIfPresent(SafeMatch.self, forKey: .matchedSafe)
        quickRejected = try container.decodeIfPresent(Bool.self, forKey: .quickRejected) ?? false
        matchingView = try container.decodeIfPresent(MatchingView.self, forKey: .matchingView)
            ?? MatchingView("")
        policyOverride = try container.decodeIfPresent(PolicyOverride.self, forKey: .policyOverride)
            ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(matched, forKey: .matched)
        try container.encodeIfPresent(matchedSafe, forKey: .matchedSafe)
        try container.encode(quickRejected, forKey: .quickRejected)
        try container.encode(matchingView, forKey: .matchingView)
        try container.encode(policyOverride, forKey: .policyOverride)
    }
}
