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
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:\(branchName)"),
                    effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                    resources: .git(
                        remote: RemoteName("origin"),
                        ref: .branch(BranchName(branchName))
                    ),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                    supportingCommand: ShellCommand(rawValue: "git push --force origin \(branchName)")
                )
            )
        )
    }

    static func plainPush(branchName: String? = "topic") -> ProposedAction {
        .shell(
            ShellAction.effectOnly(EffectShell(
                fingerprint: ActionFingerprint(rawValue: "shell:git.push:origin:\(branchName ?? "")"),
                effects: ActionEffects(kinds: [.remoteBranchMutation]),
                resources: ActionResources(remoteName: "origin", branchName: branchName),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                supportingCommand: ShellCommand(rawValue: "git push origin \(branchName ?? "")")
            ))
        )
    }

    static func implicitForcePush() -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:implicit"),
                    effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                    resources: .git(remote: RemoteName("origin"), ref: nil),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                    supportingCommand: ShellCommand(rawValue: "git push --force-with-lease")
                )
            )
        )
    }

    static func checkout(
        effects: [ActionEffectKind],
        branchName: String? = nil,
        supportingCommand: String
    ) -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:git.checkout"),
                    effects: ActionEffects(kinds: effects),
                    resources: branchName.map { name in
                        ResourceScope.git(remote: nil, ref: .branch(BranchName(name)))
                    } ?? .none,
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                    supportingCommand: ShellCommand(rawValue: supportingCommand)
                )
            )
        )
    }

    static func filesystem(
        effects: [ActionEffectKind],
        path: String,
        scope: FilesystemScope
    ) -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:fs.delete"),
                    effects: ActionEffects(kinds: effects),
                    resources: .filesystem(path: path, scope: scope, kind: .unknown),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                    supportingCommand: ShellCommand(rawValue: "rm link")
                )
            )
        )
    }

    static func uncovered(supportingCommand: String) -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:uncovered"),
                    effects: ActionEffects(),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                    supportingCommand: ShellCommand(rawValue: supportingCommand)
                )
            )
        )
    }
}
