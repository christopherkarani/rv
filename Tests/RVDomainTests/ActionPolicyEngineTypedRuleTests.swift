import Testing
import RVDomain

@Suite("ActionPolicyEngineTypedRule")
struct ActionPolicyEngineTypedRuleTests {
    private let shared = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "main",
            isSharedBranch: true
        )
    )

    private let privateBranch = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "feature",
            isSharedBranch: false
        )
    )

    @Test func typedDeny_forcePushMain_isHardDenyWithTypedRuleID() {
        let rule = typedRule(verdict: .deny)
        let git = forcePush(branchName: "main")
        let verdict = ActionPolicyEngine.evaluate(
            action: proposed(git),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule]),
            gitAction: git
        )
        guard case .hardDeny(let deny) = verdict.decision else {
            Issue.record("expected hardDeny, got \(verdict.decision)")
            return
        }
        #expect(deny.ruleID == rule.id)
        #expect(verdict.explanation.ruleID == rule.id)
        #expect(verdict.explanation.zone == .hardDeny)
    }

    @Test func typedAllow_cannotBeatBuiltinSharedBranchHardDeny() {
        let rule = typedRule(verdict: .allow)
        let git = forcePush(branchName: "main")
        let verdict = ActionPolicyEngine.evaluate(
            action: proposed(git),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule]),
            gitAction: git
        )
        #expect(verdict.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(verdict.explanation.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(verdict.explanation.zone == .hardDeny)
    }

    @Test func typedAsk_featureForcePush_isMandatoryHuman() {
        let rule = typedRule(
            id: RuleID(pack: .coreGit, pattern: "ask-force-push-feature"),
            predicate: .gitPush(force: .force, branch: "feature"),
            verdict: .ask
        )
        let git = forcePush(branchName: "feature")
        let verdict = ActionPolicyEngine.evaluate(
            action: proposed(git),
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: [rule]),
            gitAction: git
        )
        guard case .mandatoryHuman(let deny) = verdict.decision else {
            Issue.record("expected mandatoryHuman, got \(verdict.decision)")
            return
        }
        #expect(deny.ruleID == rule.id)
        #expect(verdict.explanation.ruleID == rule.id)
        #expect(verdict.explanation.zone == .mandatoryHuman)
    }

    @Test func typedAsk_cannotWeakenSharedBranchHardDeny() {
        let rule = typedRule(verdict: .ask)
        let git = forcePush(branchName: "main")
        let verdict = ActionPolicyEngine.evaluate(
            action: proposed(git),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule]),
            gitAction: git
        )
        #expect(verdict.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(verdict.explanation.zone == .hardDeny)
    }

    @Test func typedAsk_beatsTypedAllowOnFeatureForcePush() {
        let allow = typedRule(
            id: RuleID(pack: .coreGit, pattern: "allow-force-push-feature"),
            predicate: .gitPush(force: .force, branch: "feature"),
            verdict: .allow
        )
        let ask = typedRule(
            id: RuleID(pack: .coreGit, pattern: "ask-force-push-feature"),
            predicate: .gitPush(force: .force, branch: "feature"),
            verdict: .ask
        )
        let git = forcePush(branchName: "feature")
        let verdict = ActionPolicyEngine.evaluate(
            action: proposed(git),
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: [allow, ask]),
            gitAction: git
        )
        guard case .mandatoryHuman(let deny) = verdict.decision else {
            Issue.record("expected mandatoryHuman, got \(verdict.decision)")
            return
        }
        #expect(deny.ruleID == ask.id)
        #expect(verdict.explanation.zone == .mandatoryHuman)
    }

    @Test func typedDeny_doesNotReadSupportingCommand() {
        let rule = typedRule(verdict: .deny)
        let feature = forcePush(branchName: "feature")
        let featureVerdict = ActionPolicyEngine.evaluate(
            action: proposed(feature, supportingCommand: "git push --force origin main"),
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: [rule]),
            gitAction: feature
        )
        #expect(featureVerdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))

        let main = forcePush(branchName: "main")
        let mainVerdict = ActionPolicyEngine.evaluate(
            action: proposed(main, supportingCommand: "git push --force origin feature"),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule]),
            gitAction: main
        )
        guard case .hardDeny(let deny) = mainVerdict.decision else {
            Issue.record("expected hardDeny, got \(mainVerdict.decision)")
            return
        }
        #expect(deny.ruleID == rule.id)
    }

    @Test func typedDeny_doesNotMatchWhenGitActionMissing() {
        let rule = typedRule(verdict: .deny)
        let git = forcePush(branchName: "main")
        let verdict = ActionPolicyEngine.evaluate(
            action: proposed(git),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule])
        )
        #expect(verdict.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(verdict.explanation.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
    }

    @Test func resetHard_packFallbackUnchangedWhenTypedPushRuleDoesNotMatch() {
        let git = GitAction.reset(mode: .soft, target: nil)
        let typed = typedRule(verdict: .deny)
        let packDeny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes."
        )
        let denied = ActionPolicyEngine.evaluate(
            action: proposed(git, supportingCommand: "git reset --hard"),
            context: shared,
            policy: EffectiveActionPolicy(packFallback: .deny(packDeny), rules: [typed]),
            gitAction: git
        )
        #expect(denied.decision == .hardDeny(packDeny))
        #expect(denied.explanation.ruleID == packDeny.ruleID)
        #expect(denied.explanation.zone == .hardDeny)
    }
}

private func typedRule(
    id: RuleID = RuleID(pack: .coreGit, pattern: "force-push-main"),
    predicate: PolicyPredicate = .gitPush(force: .force, branch: "main"),
    verdict: TypedRuleVerdict,
    origin: TypedRuleOrigin = .machine
) -> TypedRule {
    TypedRule(id: id, predicate: predicate, verdict: verdict, origin: origin)
}

private func forcePush(branchName: String) -> GitAction {
    .push(remote: "origin", refspec: branchName, force: .force, delete: false)
}

private func proposed(_ git: GitAction, supportingCommand: String? = nil) -> ProposedAction {
    let command: String
    if let supportingCommand {
        command = supportingCommand
    } else if case .push(_, let refspec, let force, _) = git {
        let flag = force == .force ? " --force" : ""
        command = "git push\(flag) origin \(refspec ?? "")"
    } else {
        command = "git status"
    }
    return git.proposedAction(
        command: ShellCommand(rawValue: command),
        workingDirectory: WorkingDirectory(validating: "/tmp/rv")
    )
}
