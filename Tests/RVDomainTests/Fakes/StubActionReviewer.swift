import RVDomain

struct StubActionReviewer: ActionReviewer {
    var providerID: ReviewerProviderID
    var result: Result<ActionReview, ActionReviewerError>

    func review(_: ReviewRequest) async throws -> ActionReview {
        switch result {
        case .success(let review):
            return review
        case .failure(let error):
            throw error
        }
    }
}

enum ActionReviewerFixtures {
    static let fallbackDeny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "core.git"), pattern: "force-push"),
        reason: "Force-push to a shared branch needs a human or a qualified review."
    )

    static let hardDeny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "core.git"), pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes."
    )

    static func forcePushAction(
        supportingCommand: String = "git push --force origin main"
    ) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:main"),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(remoteName: "origin", branchName: "main"),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: supportingCommand)
            )
        )
    }

    static func reviewRequest(
        supportingCommand: String = "git push --force origin main",
        context: ReviewContext = ReviewContext(
            repository: RepositoryReviewContext(
                name: "rv",
                currentBranch: "main",
                isSharedBranch: true
            ),
            environment: EnvironmentReviewContext(labels: ["development"], isCI: false)
        )
    ) -> ReviewRequest {
        ReviewRequest(action: forcePushAction(supportingCommand: supportingCommand), context: context)
    }

    static func review(
        decision: ReviewDecision,
        confidence: ReviewerConfidence,
        rationaleCategory: ReviewRationaleCategory,
        rationale: String = "stub"
    ) -> ActionReview {
        ActionReview(
            decision: decision,
            risk: .high,
            confidence: confidence,
            rationale: rationale,
            rationaleCategory: rationaleCategory
        )
    }
}
