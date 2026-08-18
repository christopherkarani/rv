import Foundation
import RVDomain

public struct DenyViewModel: Equatable, Sendable {
    public var decision: Decision
    public var command: ShellCommand
    public var packID: PackID
    public var ruleID: RuleID
    public var fact: String
    public var nextAction: String

    public var ruleDisplay: String { displayRuleID(ruleID) }

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

public func factSentence(from reason: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if let end = trimmed.firstRange(of: ". ") {
        return trimmed[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if trimmed.hasSuffix(".") {
        return String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

public func denyViewModel(_ deny: Deny, command: ShellCommand) -> DenyViewModel {
    DenyViewModel(
        decision: .deny(deny),
        command: command,
        packID: deny.ruleID.pack,
        ruleID: deny.ruleID,
        fact: factSentence(from: deny.reason),
        nextAction: denyNextAction
    )
}

public func denyViewModel(from result: EvaluationResult, command: ShellCommand) -> DenyViewModel? {
    guard case .deny(let deny) = result.decision else {
        return nil
    }
    return denyViewModel(deny, command: command)
}
