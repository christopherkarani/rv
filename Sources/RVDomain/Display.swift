/// Incomplete-eval sentence shared by hook voice and TTY copy.
public let incompleteEvalSentence =
    "rv could not finish evaluating this command. Run it in Terminal."

/// Unlock next-step on hook voice. TTY deny next-action keeps its own casing.
public let hookUnlockNext = "Run it in Terminal, or rv allow-once."

public func displayRuleID(_ ruleID: RuleID) -> String {
    "\(ruleID.pack.rawValue)/\(ruleID.pattern)"
}
