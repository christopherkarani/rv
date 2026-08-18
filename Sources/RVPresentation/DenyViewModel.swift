import RVDomain

public struct DenyViewModel: Equatable, Sendable {
    public var decision: Decision
    public var command: ShellCommand
    public var packID: PackID
    public var ruleID: RuleID
    public var fact: String
    public var nextAction: String

    public init(
        decision: Decision,
        command: ShellCommand,
        packID: PackID,
        ruleID: RuleID,
        fact: String,
        nextAction: String
    ) {
        self.decision = decision
        self.command = command
        self.packID = packID
        self.ruleID = ruleID
        self.fact = fact
        self.nextAction = nextAction
    }
}

public let denyNextAction = "run it in Terminal, or rv allow-once"

public func displayRuleID(_ ruleID: RuleID) -> String {
    "\(ruleID.pack.rawValue)/\(ruleID.pattern)"
}

func trimWhitespace(_ text: String) -> String {
    String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
}

public func factSentence(from reason: String) -> String {
    let trimmed = trimWhitespace(reason)
    if let end = sentenceEnd(in: trimmed) {
        return trimWhitespace(String(trimmed[..<end]))
    }
    if trimmed.hasSuffix(".") {
        return trimWhitespace(String(trimmed.dropLast()))
    }
    return trimmed
}

private func sentenceEnd(in text: String) -> String.Index? {
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "." {
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == " " {
                return index
            }
        }
        index = text.index(after: index)
    }
    return nil
}

public func denyViewModel(from result: EvaluationResult, command: ShellCommand) -> DenyViewModel? {
    guard case .deny(let deny) = result.decision else {
        return nil
    }
    return DenyViewModel(
        decision: result.decision,
        command: command,
        packID: deny.ruleID.pack,
        ruleID: deny.ruleID,
        fact: factSentence(from: deny.reason),
        nextAction: denyNextAction
    )
}
