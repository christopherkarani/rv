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

    @Test func unsupportedReviewer_fallsBackToAskNotAllow() async {
        let reviewer = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.unsupported"),
            result: .failure(.unsupported)
        )
        let bound = await ReviewBind.apply(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision == .deny(ActionReviewerFixtures.fallbackDeny))
    }

    @Test func timeoutReviewer_fallsBackToAskNotAllow() async {
        let reviewer = StubActionReviewer(
            providerID: ReviewerProviderID(rawValue: "stub.timeout"),
            result: .failure(.timeout)
        )
        let bound = await ReviewBind.apply(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision != .allow)
    }

    @Test func lowConfidenceAllow_doesNotAuthorize() async {
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
        let bound = await ReviewBind.apply(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision != .allow)
    }

    @Test func conflictingRationale_doesNotAuthorize() async {
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
        let bound = await ReviewBind.apply(
            hardDecision: eligible,
            request: request,
            reviewer: reviewer
        )
        #expect(bound == .mandatoryHuman(ActionReviewerFixtures.fallbackDeny))
        #expect(bound.decision != .allow)
    }

    @Test func hardDeny_isNotLiftedByStubAllow() async {
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
        let bound = await ReviewBind.apply(
            hardDecision: .hardDeny(ActionReviewerFixtures.hardDeny),
            request: request,
            reviewer: reviewer
        )
        #expect(bound == .deny(ActionReviewerFixtures.hardDeny))
        #expect(bound.decision == .deny(ActionReviewerFixtures.hardDeny))
    }

    @Test func mandatoryHuman_isNotLiftedByStubAllow() async {
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
        let bound = await ReviewBind.apply(
            hardDecision: .mandatoryHuman(ask),
            request: request,
            reviewer: reviewer
        )
        #expect(bound == .mandatoryHuman(ask))
        #expect(bound.decision == .deny(ask))
    }

    @Test func swappingStubReviewers_usesDomainBindOnly() async {
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
            bounds.append(
                await ReviewBind.apply(
                    hardDecision: eligible,
                    request: request,
                    reviewer: reviewer
                )
            )
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
}
