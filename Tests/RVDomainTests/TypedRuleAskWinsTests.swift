import Testing
import RVDomain

@Suite("TypedRuleAskWins")
struct TypedRuleAskWinsTests {
    private let privateBranch = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "feature",
            isSharedBranch: false
        )
    )

    @Test(arguments: [
        [TypedRuleVerdict.allow, .ask],
        [.ask, .allow],
    ])
    func samePredicate_askAndAllow_isMandatoryHumanFromAsk(
        _ order: [TypedRuleVerdict]
    ) throws {
        let predicate = PolicyPredicate.gitPush(force: .force, branch: "feature")
        let rules = order.map { verdict in
            TypedRule(
                id: RuleID(pack: .coreGit, pattern: "\(verdict.rawValue)-force-push-feature"),
                predicate: predicate,
                verdict: verdict,
                origin: verdict == .ask ? .machine : .repo
            )
        }
        let ask = try #require(rules.first { $0.verdict == .ask })
        let allow = try #require(rules.first { $0.verdict == .allow })
        #expect(ask.predicate == allow.predicate)

        let git = GitAction.push(
            remote: "origin",
            refspec: "feature",
            force: .force,
            delete: false
        )
        let verdict = ActionPolicyEngine.evaluate(
            action: git.proposedAction(
                command: ShellCommand(rawValue: "git push --force origin feature"),
                workingDirectory: WorkingDirectory(validating: "/tmp/rv")
            ),
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: rules),
            gitAction: git
        )

        guard case .mandatoryHuman(let deny) = verdict.decision else {
            Issue.record("expected mandatoryHuman, got \(verdict.decision)")
            return
        }
        #expect(deny.ruleID == ask.id)
        #expect(verdict.explanation.ruleID == ask.id)
        #expect(verdict.explanation.zone == .mandatoryHuman)
        #expect(deny.ruleID != allow.id)
        #expect(deny.ruleID != ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID)
    }

    @Test(arguments: [
        [TypedRuleVerdict.allow, .ask],
        [.ask, .allow],
    ])
    func samePredicate_askAndAllow_onUncoveredPush_isMandatoryHumanFromAsk(
        _ order: [TypedRuleVerdict]
    ) throws {
        let predicate = PolicyPredicate.gitPush(force: GitPushForce.none, branch: "feature")
        let rules = order.map { verdict in
            TypedRule(
                id: RuleID(pack: .coreGit, pattern: "\(verdict.rawValue)-push-feature"),
                predicate: predicate,
                verdict: verdict,
                origin: .machine
            )
        }
        let ask = try #require(rules.first { $0.verdict == .ask })

        let git = GitAction.push(
            remote: "origin",
            refspec: "feature",
            force: .none,
            delete: false
        )
        let verdict = ActionPolicyEngine.evaluate(
            action: git.proposedAction(
                command: ShellCommand(rawValue: "git push origin feature"),
                workingDirectory: WorkingDirectory(validating: "/tmp/rv")
            ),
            context: privateBranch,
            policy: EffectiveActionPolicy(rules: rules),
            gitAction: git
        )

        guard case .mandatoryHuman(let deny) = verdict.decision else {
            Issue.record("expected mandatoryHuman, got \(verdict.decision)")
            return
        }
        #expect(deny.ruleID == ask.id)
        #expect(verdict.explanation.zone == .mandatoryHuman)
    }
}
