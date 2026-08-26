import Testing
import RVDomain
@testable import RVPolicy

@Suite("ShadowReviewRunner")
struct ShadowReviewRunnerTests {
    private let request = ShadowReviewFixtures.reviewRequest()
    private let eligible = ShadowReviewFixtures.eligible

    @Test func reviewEligible_invokesReviewer_logsShadow_liveStaysHuman() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            ),
            log: log
        )

        let boundIfApplied = ReviewBind.apply(
            hardDecision: eligible,
            review: .success(
                ShadowReviewFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            )
        )
        #expect(boundIfApplied == .allow)

        let result = await ShadowReviewRunner.run(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )

        #expect(await log.count == 1)
        #expect(result.shadow.invoked)
        #expect(result.shadow.decision == .allow)
        #expect(result.shadow.confidence == .high)
        #expect(result.shadow.rationaleCategory == .allow)
        #expect(result.shadow.modelUnavailable == false)
        #expect(result.shadow.disagreesWithLive)
        #expect(result.shadow.liveOutcome == .askHuman)
        #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
        #expect(result.live != boundIfApplied)
        #expect(result.live == ShadowReviewRunner.liveDecision(from: eligible))
    }

    @Test func reviewEligible_modelDeny_doesNotBecomeLiveDecision() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .deny,
                    confidence: .high,
                    rationaleCategory: .deny
                )
            ),
            log: log
        )
        let result = await ShadowReviewRunner.run(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(await log.count == 1)
        #expect(result.shadow.decision == .deny)
        #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
        #expect(result.shadow.disagreesWithLive == false)
    }

    @Test func reviewEligible_modelAbstain_doesNotBecomeLiveDecision() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .abstain,
                    confidence: .medium,
                    rationaleCategory: .uncertain
                )
            ),
            log: log
        )
        let result = await ShadowReviewRunner.run(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(await log.count == 1)
        #expect(result.shadow.decision == .abstain)
        #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
    }

    @Test func hardDeny_doesNotInvokeReviewer() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            ),
            log: log
        )
        let result = await ShadowReviewRunner.run(
            hardDecision: .hardDeny(ShadowReviewFixtures.hardDeny),
            request: request,
            reviewer: reviewer
        )
        #expect(await log.count == 0)
        #expect(result.shadow.invoked == false)
        #expect(result.shadow.decision == nil)
        #expect(result.shadow.modelUnavailable == false)
        #expect(result.live == .deny(ShadowReviewFixtures.hardDeny))
    }

    @Test func hardAllow_doesNotInvokeReviewer() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .deny,
                    confidence: .high,
                    rationaleCategory: .deny
                )
            ),
            log: log
        )
        let result = await ShadowReviewRunner.run(
            hardDecision: .hardAllow,
            request: request,
            reviewer: reviewer
        )
        #expect(await log.count == 0)
        #expect(result.shadow.invoked == false)
        #expect(result.live == .allow)
    }

    @Test func timeout_recordsFailure_doesNotWeakenLive() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(result: .failure(.timeout), log: log)
        let result = await ShadowReviewRunner.run(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(await log.count == 1)
        #expect(result.shadow.invoked)
        #expect(result.shadow.modelUnavailable)
        #expect(result.shadow.decision == nil)
        #expect(result.shadow.disagreesWithLive == false)
        #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
        #expect(result.live != .allow)
    }

    @Test func unavailable_recordsFailure_doesNotWeakenLive() async {
        let log = ReviewCallLog()
        let reviewer = FakeFoundationModelsReviewer(result: .failure(.unsupported), log: log)
        let result = await ShadowReviewRunner.run(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(await log.count == 1)
        #expect(result.shadow.modelUnavailable)
        #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
        #expect(result.live != .allow)
    }

    @Test func swappingAFMShapedReviewers_doesNotTouchLivePath() async {
        let allowLog = ReviewCallLog()
        let denyLog = ReviewCallLog()
        let allowStub = FakeFoundationModelsReviewer(
            providerID: ReviewerProviderID(rawValue: "apple.foundation-models.fake.allow"),
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            ),
            log: allowLog
        )
        let denyStub = FakeFoundationModelsReviewer(
            providerID: ReviewerProviderID(rawValue: "apple.foundation-models.fake.deny"),
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .deny,
                    confidence: .high,
                    rationaleCategory: .deny
                )
            ),
            log: denyLog
        )
        let reviewers: [any ActionReviewer] = [allowStub, denyStub]
        var shadows: [ShadowReviewRecord] = []
        for reviewer in reviewers {
            let result = await ShadowReviewRunner.run(
                hardDecision: eligible,
                request: request,
                reviewer: reviewer
            )
            #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
            shadows.append(result.shadow)
        }
        #expect(allowStub.providerID != denyStub.providerID)
        #expect(shadows.count == 2)
        #expect(shadows[0].decision == .allow)
        #expect(shadows[1].decision == .deny)
        #expect(await allowLog.count == 1)
        #expect(await denyLog.count == 1)
    }

    @Test func missingContext_isRecordedOnShadow() async {
        let log = ReviewCallLog()
        let sparse = ReviewRequest(
            action: .shell(
                ShellAction(
                    fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:main"),
                    effects: ActionEffects(kinds: [.remoteSharedBranchMutation])
                )
            ),
            context: ReviewContext(repository: RepositoryReviewContext())
        )
        let reviewer = FakeFoundationModelsReviewer(
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .abstain,
                    confidence: .low,
                    rationaleCategory: .uncertain
                )
            ),
            log: log
        )
        let result = await ShadowReviewRunner.run(
            hardDecision: eligible,
            request: sparse,
            reviewer: reviewer
        )
        #expect(
            result.shadow.missingContextReasons
                == [.repositoryName, .currentBranch, .workingDirectory]
        )
        #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
    }
}
