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
        let verdict = ActionPolicyEngine.evaluate(
            action: forcePush(branchName: "main"),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule])
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
        let verdict = ActionPolicyEngine.evaluate(
            action: forcePush(branchName: "main"),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule])
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
        let verdict = ActionPolicyEngine.evaluate(
            action: forcePush(branchName: "feature"),
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: [rule])
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
        let verdict = ActionPolicyEngine.evaluate(
            action: forcePush(branchName: "main"),
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule])
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
        let verdict = ActionPolicyEngine.evaluate(
            action: forcePush(branchName: "feature"),
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: [allow, ask])
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
        let featureNamedMain = forcePush(
            branchName: "feature",
            supportingCommand: "git push --force origin main"
        )
        let featureVerdict = ActionPolicyEngine.evaluate(
            action: featureNamedMain,
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: [rule])
        )
        #expect(featureVerdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))

        let mainNamedFeature = forcePush(
            branchName: "main",
            supportingCommand: "git push --force origin feature"
        )
        let mainVerdict = ActionPolicyEngine.evaluate(
            action: mainNamedFeature,
            context: shared,
            policy: EffectiveActionPolicy(rules: [rule])
        )
        guard case .hardDeny(let deny) = mainVerdict.decision else {
            Issue.record("expected hardDeny, got \(mainVerdict.decision)")
            return
        }
        #expect(deny.ruleID == rule.id)
    }

    @Test func resetHard_packFallbackUnchangedWhenTypedPushRuleDoesNotMatch() {
        let action = uncovered(supportingCommand: "git reset --hard")
        let typed = typedRule(verdict: .deny)
        let packDeny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes."
        )
        let denied = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: EffectiveActionPolicy(packFallback: .deny(packDeny), rules: [typed])
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

private func forcePush(
    branchName: String,
    supportingCommand: String? = nil
) -> ProposedAction {
    let command = supportingCommand ?? "git push --force origin \(branchName)"
    return .shell(
        ShellAction(
            fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:\(branchName)"),
            effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
            resources: ActionResources(remoteName: "origin", branchName: branchName),
            scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
            supportingCommand: ShellCommand(rawValue: command)
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
