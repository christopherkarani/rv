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

    @Test func typedDeny_explanationRuleID_matchesTypedRule() {
        let rule = typedPushDeny()
        let verdict = ActionPolicyEngine.evaluate(
            action: forcePush(branchName: "main"),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule])
        )
        #expect(verdict.explanation.ruleID == rule.id)
        #expect(verdict.explanation.zone == .hardDeny)
        #expect(verdict.explanation.ruleID != ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
    }

    @Test func workingTreeDiscard_explanationRuleID_staysBuiltinWhenTypedPushRulePresent() {
        let rule = typedPushDeny()
        let verdict = ActionPolicyEngine.evaluate(
            action: workingTreeDiscard(supportingCommand: "git reset --hard"),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule])
        )
        #expect(verdict.explanation.ruleID == ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID)
        #expect(verdict.explanation.zone == .hardDeny)
        #expect(verdict.explanation.ruleID != rule.id)
    }

    @Test func packResetHard_explanationRuleID_staysPackIDWhenTypedPushRulePresent() {
        let rule = typedPushDeny()
        let packDeny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes."
        )
        let verdict = ActionPolicyEngine.evaluate(
            action: uncovered(supportingCommand: "git reset --hard"),
            context: shared,
            policy: EffectiveActionPolicy(packFallback: .deny(packDeny), rules: [rule])
        )
        #expect(verdict.explanation.ruleID == packDeny.ruleID)
        #expect(verdict.explanation.ruleID.rawValue == "core.git:reset-hard")
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

private func forcePush(branchName: String) -> ProposedAction {
    .shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:\(branchName)"),
            effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
            resources: ActionResources(remoteName: "origin", branchName: branchName),
            scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
            supportingCommand: ShellCommand(rawValue: "git push --force origin \(branchName)")
        )
    )
}

private func workingTreeDiscard(supportingCommand: String) -> ProposedAction {
    .shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: "shell:git.reset-hard"),
            effects: ActionEffects(kinds: [.workingTreeDiscard]),
            scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
            supportingCommand: ShellCommand(rawValue: supportingCommand)
        )
    )
}

private func uncovered(supportingCommand: String) -> ProposedAction {
    .shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: "shell:uncovered"),
            effects: ActionEffects(),
            scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
            supportingCommand: ShellCommand(rawValue: supportingCommand)
        )
    )
}
