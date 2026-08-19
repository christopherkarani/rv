import RVDomain

public func hostDenyText(from result: EvaluationResult, command: ShellCommand) -> String? {
    switch result.decision {
    case .allow:
        return nil
    case .indeterminate:
        return incompleteEvalSentence
    case .deny(let deny):
        let commandText = String(command.rawValue.map { ch -> Character in
            (ch == "\n" || ch == "\r") ? " " : ch
        })
        return
            "Blocked \(commandText) (\(displayRuleID(deny.ruleID))). \(hookUnlockNext)"
    }
}
