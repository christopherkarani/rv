import Testing
import RVDomain

@Suite("ActionPolicyEngine")
struct ActionPolicyEngineTests {
    private let shared = ActionPolicyFixtures.sharedContext
    private let privateBranch = ActionPolicyFixtures.privateContext
    private let allowReview = ActionPolicyFixtures.qualifiedAllow

    @Test func identicalInputs_yieldIdenticalVerdict() {
        let action = ActionPolicyFixtures.forcePush()
        let policy = EffectiveActionPolicy.empty
        let first = ActionPolicyEngine.evaluate(action: action, context: shared, policy: policy)
        let second = ActionPolicyEngine.evaluate(action: action, context: shared, policy: policy)
        #expect(first == second)
        #expect(first.decision == second.decision)
        #expect(first.explanation == second.explanation)
        #expect(first.explanation.zone == .hardDeny)
        #expect(first.explanation.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
    }

    @Test func stubAllow_cannotLiftHardDeny() {
        let action = ActionPolicyFixtures.forcePush()
        let verdict = ActionPolicyEngine.evaluate(action: action, context: shared)
        #expect(verdict.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))

        let bound = ActionPolicyEngine.bind(
            action: action,
            context: shared,
            review: .success(allowReview)
        )
        #expect(bound == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(bound.decision == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(
            ReviewBind.apply(hardDecision: verdict.decision, review: .success(allowReview))
                == bound
        )
    }

    @Test func stubAllow_cannotLiftMandatoryHuman() {
        let action = ActionPolicyFixtures.forcePush(branchName: "topic")
        let verdict = ActionPolicyEngine.evaluate(action: action, context: privateBranch)
        #expect(verdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))

        let bound = ActionPolicyEngine.bind(
            action: action,
            context: privateBranch,
            review: .success(allowReview)
        )
        #expect(bound == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
        #expect(bound.decision == .deny(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func overlayAllow_cannotWeakenBuiltInHardZones() {
        let action = ActionPolicyFixtures.forcePush()
        let overlay = EffectiveActionPolicy(overlay: .allow)
        let denied = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: overlay
        )
        let asked = ActionPolicyEngine.evaluate(
            action: ActionPolicyFixtures.forcePush(branchName: "topic"),
            context: privateBranch,
            policy: overlay
        )
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(asked.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func gitCheckoutFamily_differsByEffectsNotCommandText() {
        let family = "git checkout"
        let create = ActionPolicyFixtures.checkout(
            effects: [.localBranchCreate],
            branchName: "feature",
            supportingCommand: family
        )
        let discard = ActionPolicyFixtures.checkout(
            effects: [.workingTreeDiscard],
            supportingCommand: family
        )
        let createVerdict = ActionPolicyEngine.evaluate(action: create, context: shared)
        let discardVerdict = ActionPolicyEngine.evaluate(action: discard, context: shared)

        #expect(create.supportingCommand == discard.supportingCommand)
        #expect(create.effects.kinds != discard.effects.kinds)
        #expect(createVerdict.decision != discardVerdict.decision)
        #expect(createVerdict.decision == .hardAllow)
        #expect(createVerdict.explanation.zone == .hardAllow)
        #expect(createVerdict.explanation.ruleID == ActionPolicyEngine.Builtin.localBranchCreate)
        #expect(discardVerdict.decision == .hardDeny(ActionPolicyEngine.Builtin.workingTreeDiscard))
        #expect(discardVerdict.explanation.zone == .hardDeny)
    }

    @Test func gitCheckoutConcreteCommands_areEvidenceOnly() {
        let create = ActionPolicyFixtures.checkout(
            effects: [.localBranchCreate],
            branchName: "feature",
            supportingCommand: "git checkout -- file.swift"
        )
        let discard = ActionPolicyFixtures.checkout(
            effects: [.workingTreeDiscard],
            supportingCommand: "git checkout -b feature"
        )
        let labelledCreate = ActionPolicyFixtures.checkout(
            effects: [.localBranchCreate],
            branchName: "feature",
            supportingCommand: "git checkout -b feature"
        )
        let labelledDiscard = ActionPolicyFixtures.checkout(
            effects: [.workingTreeDiscard],
            supportingCommand: "git checkout -- file.swift"
        )

        #expect(
            ActionPolicyEngine.evaluate(action: create, context: shared).decision
                == .hardAllow
        )
        #expect(
            ActionPolicyEngine.evaluate(action: discard, context: shared).decision
                == .hardDeny(ActionPolicyEngine.Builtin.workingTreeDiscard)
        )
        #expect(
            ActionPolicyEngine.evaluate(action: labelledCreate, context: shared).decision
                == ActionPolicyEngine.evaluate(action: create, context: shared).decision
        )
        #expect(
            ActionPolicyEngine.evaluate(action: labelledDiscard, context: shared).decision
                == ActionPolicyEngine.evaluate(action: discard, context: shared).decision
        )
    }

    @Test func unmatchedDestructive_packFallbackStillBlocks() {
        let action = ActionPolicyFixtures.uncovered(
            supportingCommand: "git reset --hard"
        )
        let packDeny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes."
        )
        let denied = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: EffectiveActionPolicy(packFallback: .deny(packDeny))
        )
        #expect(denied.decision == .hardDeny(packDeny))
        #expect(denied.explanation.ruleID == packDeny.ruleID)
        #expect(denied.explanation.zone == .hardDeny)

        let packAsk = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "checkout-discard"),
            reason: "Discarding files needs a human."
        )
        let asked = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: EffectiveActionPolicy(packFallback: .ask(packAsk))
        )
        #expect(asked.decision == .mandatoryHuman(packAsk))
        #expect(asked.explanation.zone == .mandatoryHuman)
    }

    @Test func packFallback_isIgnoredWhenSemanticRuleCovers() {
        let action = ActionPolicyFixtures.forcePush()
        let packAllow = EffectiveActionPolicy(packFallback: .allow)
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: packAllow
        )
        #expect(verdict.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
    }

    @Test func packFallback_fromEvaluationResultDeny() {
        let packDeny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes."
        )
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(PackFallback(result) == .deny(packDeny))
        #expect(PackFallback(EvaluationResult(outcome: .plain)) == .allow)
        #expect(
            PackFallback(EvaluationResult(outcome: .indeterminate(.corePacksUnavailable)))
                == .deny(ActionPolicyEngine.Builtin.packIncomplete)
        )
    }

    @Test func uncoveredWithoutPack_isReviewEligible() {
        let action = ActionPolicyFixtures.uncovered(supportingCommand: "echo hello")
        let verdict = ActionPolicyEngine.evaluate(action: action, context: shared)
        #expect(verdict.decision == .reviewEligible(fallback: ActionPolicyEngine.Builtin.uncovered))
        #expect(verdict.explanation.zone == .reviewEligible)
    }

    @Test func overlayAllow_cannotLiftProtectedPathMutation() {
        let action = ActionPolicyFixtures.filesystem(
            effects: [.filesystemDelete, .protectedPathMutation],
            path: "/home/.ssh/id_rsa",
            scope: .protectedPath
        )
        let denied = ActionPolicyEngine.evaluate(action: action, context: shared)
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.protectedPath))
        let overlay = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .allow)
        )
        #expect(overlay.decision == .hardDeny(ActionPolicyEngine.Builtin.protectedPath))
        let bound = ActionPolicyEngine.bind(
            action: action,
            context: shared,
            review: .success(allowReview)
        )
        #expect(bound == .deny(ActionPolicyEngine.Builtin.protectedPath))
    }

    @Test func inRepoWrite_isHardAllowAndOverlayCanTighten() {
        let write = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite],
            path: "/repo/Sources/Foo.swift",
            scope: .insideRepository
        )
        let create = ActionPolicyFixtures.filesystem(
            effects: [.filesystemCreate],
            path: "/repo/new.swift",
            scope: .insideRepository
        )
        #expect(ActionPolicyEngine.evaluate(action: write, context: shared).decision == .hardAllow)
        #expect(ActionPolicyEngine.evaluate(action: create, context: shared).decision == .hardAllow)
        #expect(
            ActionPolicyEngine.evaluate(action: write, context: shared).explanation.ruleID
                == ActionPolicyEngine.Builtin.inRepository
        )
        let overlayDeny = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "repo.policy"), pattern: "no-source-writes"),
            reason: "Repository policy forbids source writes."
        )
        let tightened = ActionPolicyEngine.evaluate(
            action: write,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .deny(overlayDeny))
        )
        #expect(tightened.decision == .hardDeny(overlayDeny))
    }

    @Test func outOfRepoWrite_isIndependentHardDeny() {
        let write = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite, .outsideRepositoryMutation],
            path: "/tmp/outside-file",
            scope: .outsideRepository
        )
        let delete = ActionPolicyFixtures.filesystem(
            effects: [.filesystemDelete, .outsideRepositoryMutation],
            path: "/tmp/outside-file",
            scope: .outsideRepository
        )
        let denied = ActionPolicyEngine.evaluate(action: write, context: shared)
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository))
        #expect(
            ActionPolicyEngine.evaluate(action: delete, context: shared).decision
                == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository)
        )
        let overlay = ActionPolicyEngine.evaluate(
            action: write,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .allow)
        )
        #expect(overlay.decision == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository))
        let bound = ActionPolicyEngine.bind(
            action: write,
            context: shared,
            review: .success(allowReview)
        )
        #expect(bound == .deny(ActionPolicyEngine.Builtin.outsideRepository))
    }

    @Test func outOfRepoRead_isIndependentlyGovernable() {
        let read = ActionPolicyFixtures.filesystem(
            effects: [.filesystemRead],
            path: "/tmp/outside-file",
            scope: .outsideRepository
        )
        let allowed = ActionPolicyEngine.evaluate(action: read, context: shared)
        #expect(allowed.decision == .hardAllow)
        #expect(allowed.explanation.ruleID == ActionPolicyEngine.Builtin.outsideRepositoryRead)
        let overlayDeny = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "repo.policy"), pattern: "no-outside-reads"),
            reason: "Repository policy forbids outside reads."
        )
        let tightened = ActionPolicyEngine.evaluate(
            action: read,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .deny(overlayDeny))
        )
        #expect(tightened.decision == .hardDeny(overlayDeny))
        #expect(
            ActionPolicyEngine.evaluate(
                action: ActionPolicyFixtures.filesystem(
                    effects: [.filesystemOverwrite, .outsideRepositoryMutation],
                    path: "/tmp/outside-file",
                    scope: .outsideRepository
                ),
                context: shared,
                policy: EffectiveActionPolicy(overlay: .deny(overlayDeny))
            ).decision == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository)
        )
    }

    @Test func unresolvedFilesystem_isFailClosed() {
        let unknown = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite, .unresolvedFilesystem],
            path: "/gone/file",
            scope: .unknown
        )
        let denied = ActionPolicyEngine.evaluate(action: unknown, context: shared)
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.unresolvedFilesystem))
        let overlay = ActionPolicyEngine.evaluate(
            action: unknown,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .allow)
        )
        #expect(overlay.decision == .hardDeny(ActionPolicyEngine.Builtin.unresolvedFilesystem))
    }

    @Test func overlayDeny_canTightenHardAllow() {
        let action = ActionPolicyFixtures.checkout(
            effects: [.localBranchCreate],
            branchName: "feature",
            supportingCommand: "git checkout -b feature"
        )
        let overlayDeny = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "repo.policy"), pattern: "no-branches"),
            reason: "Repository policy forbids new branches."
        )
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .deny(overlayDeny))
        )
        #expect(verdict.decision == .hardDeny(overlayDeny))
    }
}

private enum ActionPolicyFixtures {
    static let sharedContext = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "main",
            isSharedBranch: true
        )
    )

    static let privateContext = ReviewContext(
        repository: RepositoryReviewContext(
            name: "rv",
            currentBranch: "topic",
            isSharedBranch: false
        )
    )

    static let qualifiedAllow = ActionReview(
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
