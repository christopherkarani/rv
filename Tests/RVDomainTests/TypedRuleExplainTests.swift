import Testing
import RVDomain

@Suite("TypedRuleExplain")
struct TypedRuleExplainTests {
    private let shared = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "main",
            isSharedBranch: true
        )
    )

    @Test func workingTreeDiscard_explanationRuleID_staysBuiltinWhenTypedPushRulePresent() {
        let rule = typedPushDeny()
        let git = GitAction.reset(mode: .hard, target: nil)
        let verdict = ActionPolicyEngine.evaluate(
            action: proposed(git, supportingCommand: "git reset --hard"),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule]),
            gitAction: git
        )
        #expect(verdict.explanation.ruleID == ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID)
        #expect(verdict.explanation.zone == .hardDeny)
        #expect(verdict.explanation.ruleID != rule.id)
    }
}

private func typedPushDeny() -> TypedRule {
    TypedRule(
        id: RuleID(pack: .coreGit, pattern: "force-push-main"),
        predicate: .gitPush(force: .force, branch: "main"),
        verdict: .deny,
        origin: .machine
    )
}

private func proposed(_ git: GitAction, supportingCommand: String) -> ProposedAction {
    git.proposedAction(
        command: ShellCommand(rawValue: supportingCommand),
        workingDirectory: WorkingDirectory(validating: "/tmp/rv")
    )
}
