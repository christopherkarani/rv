import RVDomain

public let testMatchSource = "pack"

public struct TestViewModel: Equatable, Sendable {
    public var command: ShellCommand
    public var span: MatchSpan?
    public var matchedLabel: String?
    public var packDisplay: String?
    public var patternName: String?
    public var reason: String?
    public var explanation: String?
    public var source: String?
    public var resultWord: String
    public var resultTone: DecisionTone
    public var columns: Int
    public var deny: DenyViewModel?

    public init(
        command: ShellCommand,
        span: MatchSpan? = nil,
        matchedLabel: String? = nil,
        packDisplay: String? = nil,
        patternName: String? = nil,
        reason: String? = nil,
        explanation: String? = nil,
        source: String? = nil,
        resultWord: String,
        resultTone: DecisionTone,
        columns: Int = 80,
        deny: DenyViewModel? = nil
    ) {
        self.command = command
        self.span = span
        self.matchedLabel = matchedLabel
        self.packDisplay = packDisplay
        self.patternName = patternName
        self.reason = reason
        self.explanation = explanation
        self.source = source
        self.resultWord = resultWord
        self.resultTone = resultTone
        self.columns = max(16, columns)
        self.deny = deny
    }
}

public func remapMatchSpan(
    span: MatchSpan?,
    matchedText: String?,
    searchText: String? = nil,
    onto command: String
) -> MatchSpan? {
    if let search = searchText, !search.isEmpty, let found = command.range(of: search) {
        let offset = command.distance(from: command.startIndex, to: found.lowerBound)
        if let span {
            let mapped = MatchSpan(start: span.start + offset, end: span.end + offset)
            if mapped.start >= 0, mapped.end <= command.count, mapped.end > mapped.start {
                return mapped
            }
        }
        if let text = matchedText, !text.isEmpty, let inner = search.range(of: text) {
            let innerStart = search.distance(from: search.startIndex, to: inner.lowerBound)
            let innerEnd = search.distance(from: search.startIndex, to: inner.upperBound)
            let mapped = MatchSpan(start: innerStart + offset, end: innerEnd + offset)
            if mapped.end <= command.count, mapped.end > mapped.start {
                return mapped
            }
        }
        return nil
    }
    if searchText == nil || searchText != command {
        if let text = matchedText, !text.isEmpty, let range = command.range(of: text) {
            let start = command.distance(from: command.startIndex, to: range.lowerBound)
            let end = command.distance(from: command.startIndex, to: range.upperBound)
            if end > start {
                return MatchSpan(start: start, end: end)
            }
        }
    }
    if let span, searchText == command, span.start >= 0, span.end <= command.count, span.end > span.start {
        return span
    }
    return nil
}

public func testViewModel(
    from result: EvaluationResult,
    command: ShellCommand,
    columns: Int = 80
) -> TestViewModel {
    let resultWord = testResultWord(result.decision)
    let tone = decisionTone(result.decision)
    switch result.outcome {
    case .quickRejected, .plain, .safeOnly:
        return TestViewModel(
            command: command,
            resultWord: resultWord,
            resultTone: tone,
            columns: columns
        )
    case .hit(let match, _):
        return TestViewModel(
            command: command,
            span: remapMatchSpan(
                span: match.span,
                matchedText: match.matchedText,
                searchText: match.searchText,
                onto: command.rawValue
            ),
            matchedLabel: match.ruleID.rawValue,
            resultWord: resultWord,
            resultTone: tone,
            columns: columns
        )
    case .deny(let payload, let matched):
        let deny = denyViewModel(payload, command: command)
        return TestViewModel(
            command: command,
            span: remapMatchSpan(
                span: matched?.span,
                matchedText: matched?.matchedText,
                searchText: matched?.searchText,
                onto: command.rawValue
            ),
            matchedLabel: (matched?.ruleID ?? deny.ruleID).rawValue,
            packDisplay: deny.packID.rawValue,
            patternName: deny.ruleID.pattern,
            reason: deny.packReason,
            explanation: matched?.explanation,
            source: testMatchSource,
            resultWord: resultWord,
            resultTone: tone,
            columns: columns,
            deny: deny
        )
    case .indeterminate:
        return TestViewModel(
            command: command,
            reason: incompleteEvalSentence,
            resultWord: resultWord,
            resultTone: tone,
            columns: columns
        )
    }
}
