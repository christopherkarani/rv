import Testing
import RVDomain
@testable import RVPolicy

@Suite("FoundationModelsActionReviewer")
struct FoundationModelsActionReviewerTests {
    @Test func constructsOnThisHost() {
        let reviewer = FoundationModelsActionReviewer()
        #expect(reviewer.providerID == FoundationModelsActionReviewer.defaultProviderID)
        #expect(reviewer.timeout == FoundationModelsActionReviewer.defaultTimeout)
        #expect(reviewer.usesSystemModel)
    }

    @Test func secretsNeverEnterCapturedPayload() async {
        let secret = "ghp_NeverInPrompt99"
        let dirty = ReviewContext(
            repository: RepositoryReviewContext(name: secret, currentBranch: "main"),
            environment: EnvironmentReviewContext(labels: ["GITHUB_TOKEN", "development"]),
            metadata: [
                "GITHUB_TOKEN": secret,
                "note": "safe-label",
                "Authorization": "Bearer \(secret)",
            ]
        )
        let request = ReviewRequest(
            action: ShadowReviewFixtures.forcePushAction(
                supportingCommand: "GITHUB_TOKEN=\(secret) git push --force origin main"
            ),
            context: dirty
        )
        let box = PayloadBox()
        let reviewer = FoundationModelsActionReviewer(usesSystemModel: false) { payload in
            box.payload = payload
        }

        await #expect(throws: ActionReviewerError.unsupported) {
            try await reviewer.review(request)
        }

        let payload = try #require(box.payload)
        #expect(payload.text.contains(secret) == false)
        #expect(payload.text.contains("ghp_") == false)
        #expect(payload.text.contains("safe-label"))
        #expect(payload.text.contains("effects: remoteSharedBranchMutation"))
        #expect(payload.text.contains("resources.remoteName: origin"))
        #expect(payload.text.contains(ReviewSanitizer.redactedPlaceholder))
    }

    @Test func prompt_putsSemanticFieldsBeforeSupportingCommand() throws {
        let payload = ReviewPromptBuilder.payload(for: ShadowReviewFixtures.reviewRequest())
        let effects = try #require(payload.text.range(of: "effects:"))
        let supporting = try #require(payload.text.range(of: "supportingCommand"))
        #expect(effects.lowerBound < supporting.lowerBound)
        #expect(payload.text.contains("kind: shell"))
        #expect(payload.text.contains("fingerprint: shell:git.force-push:origin:main"))
        #expect(payload.text.contains("resources.branchName: main"))
        #expect(payload.text.contains("repository.isSharedBranch: true"))
    }

    @Test func builder_redactsSecretInSupportingCommand() {
        let request = ReviewRequest(
            action: ShadowReviewFixtures.forcePushAction(
                supportingCommand: "OPENAI_KEY=sk-proj-example git push --force origin main"
            ),
            context: ReviewContext(
                repository: RepositoryReviewContext(name: "rv", currentBranch: "main")
            )
        )
        let payload = ReviewPromptBuilder.payload(for: request)
        #expect(payload.text.contains("sk-proj-example") == false)
        #expect(payload.text.contains("OPENAI_KEY=[redacted]"))
        #expect(payload.text.contains("git push --force origin main"))
    }

    #if !canImport(FoundationModels)
    @Test func linuxHost_reviewerDegradesToUnsupported() async {
        let reviewer = FoundationModelsActionReviewer()
        await #expect(throws: ActionReviewerError.unsupported) {
            try await reviewer.review(ShadowReviewFixtures.reviewRequest())
        }
    }

    @Test func linuxHost_shadowRunRecordsUnavailableWithoutWeakeningLive() async {
        let result = await ShadowReviewRunner.run(
            hardDecision: ShadowReviewFixtures.eligible,
            request: ShadowReviewFixtures.reviewRequest(),
            reviewer: FoundationModelsActionReviewer()
        )
        #expect(result.live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))
        #expect(result.shadow.invoked)
        #expect(result.shadow.modelUnavailable)
        #expect(result.live != .allow)
    }
    #endif

    @Test func reviewTimeout_expiresSlowOperation() async {
        await #expect(throws: ActionReviewerError.timeout) {
            try await ReviewTimeout.run(timeout: .milliseconds(20)) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
    }

    @Test func reviewTimeout_returnsFastOperation() async throws {
        let value = try await ReviewTimeout.run(timeout: .seconds(1)) {
            7
        }
        #expect(value == 7)
    }

    @Test func promotionThresholds_areMeasurableAndDoNotEnableAutoReview() {
        #expect(AutoReviewPromotionThresholds.maximumFalseAllowRate > 0)
        #expect(AutoReviewPromotionThresholds.maximumFalseAllowRate < 1)
        #expect(AutoReviewPromotionThresholds.minimumHumanInterruptionReduction > 0)
        #expect(AutoReviewPromotionThresholds.minimumHumanInterruptionReduction < 1)
        #expect(AutoReviewPromotionThresholds.minimumHumanAgreementRate > 0)
        #expect(AutoReviewPromotionThresholds.minimumHumanAgreementRate <= 1)
        #expect(AutoReviewPromotionThresholds.minimumSampleSize >= 100)
    }

    @Test func swapStillGoesThroughActionReviewerOnly() async {
        let log = ReviewCallLog()
        let fake = FakeFoundationModelsReviewer(
            result: .success(
                ShadowReviewFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            ),
            log: log
        )
        let reviewers: [any ActionReviewer] = [
            FoundationModelsActionReviewer(usesSystemModel: false),
            fake,
        ]
        #expect(reviewers[0].providerID != reviewers[1].providerID)

        let live = ShadowReviewRunner.liveDecision(from: ShadowReviewFixtures.eligible)
        #expect(live == .mandatoryHuman(ShadowReviewFixtures.fallbackDeny))

        let afm = await ShadowReviewRunner.run(
            hardDecision: ShadowReviewFixtures.eligible,
            request: ShadowReviewFixtures.reviewRequest(),
            reviewer: reviewers[0]
        )
        let swapped = await ShadowReviewRunner.run(
            hardDecision: ShadowReviewFixtures.eligible,
            request: ShadowReviewFixtures.reviewRequest(),
            reviewer: reviewers[1]
        )
        #expect(afm.live == live)
        #expect(afm.shadow.modelUnavailable)
        #expect(swapped.live == live)
        #expect(swapped.shadow.decision == .allow)
        #expect(await log.count == 1)
    }
}
