import RVDomain

/// Unlock next-step on hook voice. TTY deny next-action keeps its own casing.
public let hookUnlockNext = "Run it in Terminal, or rv allow-once."

public func hostDenyLine(command: ShellCommand, ruleID: RuleID) -> String {
    let commandText = String(command.rawValue.map { ch -> Character in
        (ch == "\n" || ch == "\r") ? " " : ch
    })
    return "Blocked \(commandText) (\(displayRuleID(ruleID))). \(hookUnlockNext)"
}

public func hostDenyText(from result: EvaluationResult, command: ShellCommand) -> String? {
    switch result.decision {
    case .allow:
        return nil
    case .indeterminate:
        return incompleteEvalSentence
    case .deny(let deny):
        return hostDenyLine(command: command, ruleID: deny.ruleID)
    }
}
