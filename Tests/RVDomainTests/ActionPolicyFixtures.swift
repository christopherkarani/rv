import RVDomain

/// Shared IR for `ActionPolicyEngine` and `AgentAuthorization` tests.
/// Lifted from the engine suite so authorization tests reuse the same fixtures.
enum ActionPolicyFixtures {
    static let sharedContext = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "main"
        )
    )

    static let privateContext = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "topic"
        )
    )

    static let qualifiedAllow = ActionReview.make(
        decision: .allow,
        risk: .low,
        confidence: .high,
        rationale: "stub allow",
        rationaleCategory: .allow
    )

    static func forcePush(branchName: String = "main") -> ProposedAction {
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

    static func implicitForcePush() -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:implicit"),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(remoteName: "origin"),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: "git push --force-with-lease")
            )
        )
    }

    static func checkout(
        effects: [ActionEffectKind],
        branchName: String? = nil,
        supportingCommand: String
    ) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:git.checkout"),
                effects: ActionEffects(kinds: effects),
                resources: ActionResources(branchName: branchName),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: supportingCommand)
            )
        )
    }

    static func filesystem(
        effects: [ActionEffectKind],
        path: String,
        scope: FilesystemScope
    ) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:fs.delete"),
                effects: ActionEffects(kinds: effects),
                resources: ActionResources(
                    path: path,
                    filesystemScope: scope,
                    resourceKind: .unknown
                ),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: "rm link")
            )
        )
    }

    static func uncovered(supportingCommand: String) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:uncovered"),
                effects: ActionEffects(),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: supportingCommand)
            )
        )
    }
}
