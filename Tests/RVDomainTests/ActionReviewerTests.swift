import Foundation
import Testing
import RVDomain

@Suite("ActionReviewer")
struct ActionReviewerTests {
    private let eligible = HardPolicyDecision.reviewEligible(
        fallback: ActionReviewerFixtures.fallbackDeny
    )
    private let request = ActionReviewerFixtures.reviewRequest()

    @Test func reviewRequest_exposesSemanticForcePush_notRawShellAsPrimary() {
        let request = ActionReviewerFixtures.reviewRequest()
        guard case .shell(let shell) = request.action else {
            Issue.record("expected shell action")
            return
        }
        #expect(shell.effects.kinds == [.remoteSharedBranchMutation])
        #expect(shell.resources.remoteName == "origin")
        #expect(shell.resources.branchName == "main")
        #expect(shell.scope.workingDirectory?.rawValue == "/tmp/rv")
        #expect(request.action.fingerprint.rawValue == "shell:git.force-push:origin:main")
        #expect(request.context.repository.isSharedBranch)
        #expect(request.context.repository.currentBranch == "main")
        #expect(shell.supportingCommand?.rawValue == "git push --force origin main")
    }

    @Test func reviewContext_stripsRawCredentials() {
        let dirty = ReviewContext(
            repository: RepositoryReviewContext(name: "ghp_exampletoken"),
            environment: EnvironmentReviewContext(labels: ["GITHUB_TOKEN", "development"]),
            metadata: [
                "GITHUB_TOKEN": "ghp_secret",
                "note": "safe-label",
                "Authorization": "Bearer supersecret",
            ]
        )
        let request = ReviewRequest(
            action: ActionReviewerFixtures.forcePushAction(
                supportingCommand: "GITHUB_TOKEN=ghp_secret git push --force origin main"
            ),
            context: dirty
        )

        #expect(request.context.metadata["GITHUB_TOKEN"] == nil)
        #expect(request.context.metadata["Authorization"] == nil)
        #expect(request.context.metadata["note"] == "safe-label")
        #expect(request.context.environment.labels == ["development"])
        #expect(request.context.repository.name == ReviewSanitizer.redactedPlaceholder)
        #expect(request.action.supportingCommand?.rawValue.contains("ghp_secret") == false)
        #expect(
            request.action.supportingCommand?.rawValue.contains("GITHUB_TOKEN=[redacted]") == true
        )
        #expect(
            request.action.supportingCommand?.rawValue.contains("git push --force origin main")
                == true
        )
    }

    @Test func reviewRequest_redactsSecretShapedValuesAndMidTokenPrefixes() {
        let dirty = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(
                    rawValue: "shell:git.push https://ghp_exampletoken@github.com/org/repo.git"
                ),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(remoteName: "origin", branchName: "main"),
                scope: ActionScope(
                    workingDirectory: WorkingDirectory(validating: "/tmp/ghp_exampletoken")
                ),
                supportingCommand: ShellCommand(
                    rawValue: "COUNT=2 FOO=ghp_exampletoken OPENAI_KEY=sk-proj-example git push https://ghp_exampletoken@github.com/org/repo.git"
                )
            )
        )
        let request = ReviewRequest(
            action: dirty,
            context: ReviewContext(
                repository: RepositoryReviewContext(name: "rv", currentBranch: "main")
            )
        )

        #expect(request.action.fingerprint.rawValue.contains("ghp_exampletoken") == false)
        #expect(
            request.action.fingerprint.rawValue
                == "shell:git.push \(ReviewSanitizer.redactedPlaceholder)"
        )
        #expect(request.action.supportingCommand?.rawValue.contains("ghp_exampletoken") == false)
        #expect(request.action.supportingCommand?.rawValue.contains("sk-proj-example") == false)
        #expect(request.action.supportingCommand?.rawValue.contains("COUNT=2") == true)
        #expect(request.action.supportingCommand?.rawValue.contains("FOO=[redacted]") == true)
        #expect(
            request.action.supportingCommand?.rawValue.contains("OPENAI_KEY=[redacted]") == true
        )
        #expect(request.action.supportingCommand?.rawValue.contains("git push") == true)
        #expect(
            request.action.supportingCommand?.rawValue.contains(
                "git push \(ReviewSanitizer.redactedPlaceholder)"
            ) == true
        )
        guard case .shell(let shell) = request.action else {
            Issue.record("expected shell action")
            return
        }
        #expect(shell.scope.workingDirectory?.rawValue.contains("ghp_exampletoken") == false)
        #expect(shell.scope.workingDirectory?.rawValue == ReviewSanitizer.redactedPlaceholder)
    }

    @Test func unsupportedReviewer_fallsBackToAskNotAllow() {
        let bound = ReviewBind.apply(
            hardDecision: eligible,
            review: .failure(.unsupported)
        )
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision == .deny(ActionReviewerFixtures.fallbackDeny))
    }

    @Test func timeoutReviewer_fallsBackToAskNotAllow() {
        let bound = ReviewBind.apply(
            hardDecision: eligible,
            review: .failure(.timeout)
        )
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision != .allow)
    }

    @Test func lowConfidenceAllow_doesNotAuthorize() async throws {
        let reviewer = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.low-confidence"),
            result: .success(
                ActionReviewerFixtures.review(
                    decision: .allow,
                    confidence: .low,
                    rationaleCategory: .allow
                )
            )
        )
        let review = try await reviewer.review(request)
        let bound = ReviewBind.apply(hardDecision: eligible, review: .success(review))
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision != .allow)
    }

    @Test func conflictingRationale_doesNotAuthorize() async throws {
        let reviewer = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.conflict"),
            result: .success(
                ActionReviewerFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .deny,
                    rationale: "looks destructive"
                )
            )
        )
        let review = try await reviewer.review(request)
        let bound = ReviewBind.apply(hardDecision: eligible, review: .success(review))
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision != .allow)
    }

    @Test func abstain_doesNotAuthorize() {
        let abstain = ActionReviewerFixtures.review(
            decision: .abstain,
            confidence: .high,
            rationaleCategory: .abstain
        )
        let bound = ReviewBind.apply(hardDecision: eligible, review: .success(abstain))
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision != .allow)
    }

    @Test func hardDeny_isNotLiftedByStubAllow() async throws {
        let reviewer = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.allow"),
            result: .success(
                ActionReviewerFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            )
        )
        let review = try await reviewer.review(request)
        let bound = ReviewBind.apply(
            hardDecision: .hardDeny(ActionReviewerFixtures.hardDeny),
            review: .success(review)
        )
        #expect(bound == .deny(ActionReviewerFixtures.hardDeny))
        #expect(bound.decision == .deny(ActionReviewerFixtures.hardDeny))
    }

    @Test func mandatoryHuman_isNotLiftedByStubAllow() async throws {
        let ask = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "core.git"), pattern: "force-push"),
            reason: "Shared-branch mutation needs a human."
        )
        let reviewer = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.allow"),
            result: .success(
                ActionReviewerFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            )
        )
        let review = try await reviewer.review(request)
        let bound = ReviewBind.apply(
            hardDecision: .mandatoryHuman(ask),
            review: .success(review)
        )
        #expect(bound == .mandatoryHuman(ask))
        #expect(bound.decision == .deny(ask))
    }

    @Test func swappingStubReviewers_usesDomainBindOnly() async throws {
        let allowStub = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.allow"),
            result: .success(
                ActionReviewerFixtures.review(
                    decision: .allow,
                    confidence: .high,
                    rationaleCategory: .allow
                )
            )
        )
        let denyStub = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.deny"),
            result: .success(
                ActionReviewerFixtures.review(
                    decision: .deny,
                    confidence: .high,
                    rationaleCategory: .deny
                )
            )
        )
        let reviewers: [any ActionReviewer] = [allowStub, denyStub]
        var bounds: [BoundReview] = []
        for reviewer in reviewers {
            let review = try await reviewer.review(request)
            bounds.append(ReviewBind.apply(hardDecision: eligible, review: .success(review)))
        }
        #expect(allowStub.providerID != denyStub.providerID)
        #expect(bounds.count == 2)
        #expect(bounds[0] == .allow)
        #expect(bounds[1] == .deny(ActionReviewerFixtures.fallbackDeny))
    }

    @Test func qualifiedAllow_appliesOnlyWhenReviewEligible() {
        let allow = ActionReviewerFixtures.review(
            decision: .allow,
            confidence: .medium,
            rationaleCategory: .allow
        )
        #expect(
            ReviewBind.apply(hardDecision: eligible, review: .success(allow)) == .allow
        )
        #expect(
            ReviewBind.apply(
                hardDecision: .hardDeny(ActionReviewerFixtures.hardDeny),
                review: .success(allow)
            ) == .deny(ActionReviewerFixtures.hardDeny)
        )
    }

    @Test func hardAllow_isNotWeakenedByDenyReview() {
        let denyReview = ActionReviewerFixtures.review(
            decision: .deny,
            confidence: .high,
            rationaleCategory: .deny
        )
        #expect(
            ReviewBind.apply(hardDecision: .hardAllow, review: .success(denyReview)) == .allow
        )
    }

    @Test func reviewerConfidence_mediumAndHighAdvise_lowDoesNot() {
        #expect(ReviewerConfidence.low.isSufficientToAdvise == false)
        #expect(ReviewerConfidence.medium.isSufficientToAdvise)
        #expect(ReviewerConfidence.high.isSufficientToAdvise)
    }

    @Test func actionReview_conflictingRationale_isSymmetric() {
        let allowDeny = ActionReviewerFixtures.review(
            decision: .allow,
            confidence: .high,
            rationaleCategory: .deny
        )
        let denyAllow = ActionReviewerFixtures.review(
            decision: .deny,
            confidence: .high,
            rationaleCategory: .allow
        )
        let aligned = ActionReviewerFixtures.review(
            decision: .deny,
            confidence: .high,
            rationaleCategory: .deny
        )
        let abstain = ActionReviewerFixtures.review(
            decision: .abstain,
            confidence: .high,
            rationaleCategory: .uncertain
        )
        #expect(allowDeny.hasConflictingRationale)
        #expect(denyAllow.hasConflictingRationale)
        #expect(aligned.hasConflictingRationale == false)
        #expect(abstain.hasConflictingRationale == false)
    }

    @Test func repositoryReviewContext_sharedBranchIsMainOrMasterOnly() {
        #expect(RepositoryReviewContext(currentBranch: "main").isSharedBranch)
        #expect(RepositoryReviewContext(currentBranch: "master").isSharedBranch)
        #expect(RepositoryReviewContext(currentBranch: "feature").isSharedBranch == false)
        #expect(RepositoryReviewContext().isSharedBranch == false)
    }

    @Test func reviewTypes_roundTripCodable() throws {
        let provider = ReviewerProviderID(rawValue: "stub.codec")
        #expect(try JSONDecoder().decode(ReviewerProviderID.self, from: JSONEncoder().encode(provider)) == provider)

        let review = ActionReview(
            decision: .abstain,
            risk: .critical,
            confidence: .low,
            rationale: "not enough context",
            rationaleCategory: .uncertain
        )
        let decodedReview = try JSONDecoder().decode(ActionReview.self, from: JSONEncoder().encode(review))
        #expect(decodedReview == review)
        #expect(RiskLevel.low != .medium)
        #expect(ReviewDecision.allow != .deny)

        let context = ReviewContext(
            repository: RepositoryReviewContext(name: "rv", currentBranch: "feature"),
            environment: EnvironmentReviewContext(labels: ["dev"], isCI: true),
            metadata: ["note": "ok"]
        )
        let request = ReviewRequest(action: ActionReviewerFixtures.forcePushAction(), context: context)
        let decodedRequest = try JSONDecoder().decode(ReviewRequest.self, from: JSONEncoder().encode(request))
        #expect(decodedRequest == request)
        #expect(decodedRequest.context.environment.isCI)
        #expect(decodedRequest.context.repository.isSharedBranch == false)
    }

    @Test func reviewRequest_fileAction_isSanitizedOnInit() {
        let dirty = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:claude:::read:/tmp/ghp_exampletoken/.env"),
                file: FileToolAction(
                    kind: .read,
                    path: FileToolPath(rawValue: "/tmp/ghp_exampletoken/.env")
                ),
                effects: ActionEffects(),
                resources: ActionResources(path: "/tmp/ghp_exampletoken/.env"),
                scope: ActionScope(
                    workingDirectory: WorkingDirectory(validating: "/tmp/ghp_exampletoken")
                )
            )
        )
        let request = ReviewRequest(
            action: dirty,
            context: ReviewContext(repository: RepositoryReviewContext(name: "rv"))
        )
        guard case .file(let file) = request.action else {
            Issue.record("expected file action")
            return
        }
        #expect(file.file.path.rawValue.contains("ghp_exampletoken") == false)
        #expect(file.scope.workingDirectory?.rawValue == ReviewSanitizer.redactedPlaceholder)
    }

    @Test func reviewEligible_unalignedDecisionCategory_isAsk() {
        let unaligned = ActionReviewerFixtures.review(
            decision: .allow,
            confidence: .high,
            rationaleCategory: .abstain
        )
        #expect(
            ReviewBind.apply(hardDecision: eligible, review: .success(unaligned))
                == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny)
        )
    }
}
