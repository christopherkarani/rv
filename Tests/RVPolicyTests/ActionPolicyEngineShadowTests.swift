import Testing
import RVDomain
@testable import RVPolicy

@Suite("ActionPolicyEngine shadow wire")
struct ActionPolicyEngineShadowTests {
    private let shared = ActionPolicyEngineShadowFixtures.sharedContext

    @Test func engineHardDeny_skipsReviewer() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(ActionPolicyEngineShadowFixtures.allowReview),
            log: log
        )
        let action = ActionPolicyEngineShadowFixtures.forcePush()
        let verdict = ActionPolicyEngine.evaluate(action: action, context: shared)
        #expect(verdict.decision.zone == .hardDeny)

        let result = await ShadowReviewRunner.run(
            action: action,
            context: shared,
            policy: .empty,
            reviewer: reviewer
        )
        #expect(await log.count == 0)
        #expect(result.shadow.invoked == false)
        #expect(result.live == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(result.live == ShadowReviewRunner.liveDecision(from: verdict.decision))
    }

    @Test func engineHardAllow_skipsReviewer() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(ActionPolicyEngineShadowFixtures.denyReview),
            log: log
        )
        let action = ActionPolicyEngineShadowFixtures.checkout(
            effects: [.localBranchCreate],
            supportingCommand: "git checkout -b feature"
        )
        let verdict = ActionPolicyEngine.evaluate(action: action, context: shared)
        #expect(verdict.decision == .hardAllow)

        let result = await ShadowReviewRunner.run(
            action: action,
            context: shared,
            policy: .empty,
            reviewer: reviewer
        )
        #expect(await log.count == 0)
        #expect(result.shadow.invoked == false)
        #expect(result.live == .allow)
    }

    @Test func engineReviewEligible_invokesReviewer_liveStaysHuman() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(ActionPolicyEngineShadowFixtures.allowReview),
            log: log
        )
        let action = ActionPolicyEngineShadowFixtures.uncovered()
        let verdict = ActionPolicyEngine.evaluate(action: action, context: shared)
        #expect(verdict.decision.zone == .reviewEligible)

        let result = await ShadowReviewRunner.run(
            action: action,
            context: shared,
            policy: .empty,
            reviewer: reviewer
        )
        #expect(await log.count == 1)
        #expect(result.shadow.invoked)
        #expect(result.shadow.decision == .allow)
        #expect(result.live == .mandatoryHuman(ActionPolicyEngine.Builtin.uncovered))
        #expect(result.live == ShadowReviewRunner.liveDecision(from: verdict.decision))
        #expect(result.live != .allow)
    }
}

private enum ActionPolicyEngineShadowFixtures {
    static let sharedContext = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "main",
            isSharedBranch: true
        )
    )

    static let allowReview = ActionReview(
        decision: .allow,
        risk: .low,
        confidence: .high,
        rationale: "shadow stub",
        rationaleCategory: .allow
    )

    static let denyReview = ActionReview(
        decision: .deny,
        risk: .high,
        confidence: .high,
        rationale: "shadow stub",
        rationaleCategory: .deny
    )

    static func forcePush() -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:main"),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(remoteName: "origin", branchName: "main"),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: "git push --force origin main")
            )
        )
    }

    static func checkout(
        effects: [ActionEffectKind],
        supportingCommand: String
    ) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:git.checkout"),
                effects: ActionEffects(kinds: effects),
                resources: ActionResources(branchName: "feature"),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: supportingCommand)
            )
        )
    }

    static func uncovered() -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:uncovered"),
                effects: ActionEffects(),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: "echo hello")
            )
        )
    }
}
