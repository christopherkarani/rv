/// Incomplete-eval sentence shared by hook voice and TTY copy.
public let incompleteEvalSentence =
    "rv could not finish evaluating this command. Run it in Terminal."

/// Slash display (`core.git/reset-hard`); `RuleID.rawValue` is colon (`core.git:reset-hard`).
public func displayRuleID(_ ruleID: RuleID) -> String {
    "\(ruleID.pack.rawValue)/\(ruleID.pattern)"
}
