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
        let first = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: policy,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        let second = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: policy,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(first == second)
        #expect(first.decision == second.decision)
        #expect(first.explanation == second.explanation)
        #expect(first.explanation.zone == .hardDeny)
        #expect(first.explanation.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
    }

    @Test func stubAllow_cannotLiftHardDeny() {
        let action = ActionPolicyFixtures.forcePush()
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
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
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: privateBranch,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: privateBranch)
        )
        #expect(verdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))

        let bound = ActionPolicyEngine.bind(
            action: action,
            context: privateBranch,
            review: .success(allowReview)
        )
        #expect(bound == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
        #expect(bound.decision == .deny(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func secretRequest_isMandatoryHumanAndReviewCannotLiftIt() {
        let action = ProposedAction.secretRequest(SecretRequestAction(
            secret: "GH", method: "POST", host: "api.example.com", path: "/repos/o/r/merges",
            targetSHA256: "t", bodySHA256: "b", bodyBytes: 1, headersSHA256: "h", operationHeaders: []))
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: privateBranch,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: privateBranch)
        )
        #expect(verdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.secretRequestApproval))
        let bound = ActionPolicyEngine.bind(action: action, context: privateBranch, review: .success(allowReview))
        #expect(bound == .mandatoryHuman(ActionPolicyEngine.Builtin.secretRequestApproval))
    }

    @Test func plainPush_isMandatoryHumanOnPrivateBranch() {
        let verdict = ActionPolicyEngine.evaluate(
            action: ActionPolicyFixtures.plainPush(branchName: "topic"),
            context: privateBranch,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: privateBranch)
        )
        #expect(verdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
        #expect(verdict.explanation.zone == .mandatoryHuman)
    }

    @Test func plainPush_isMandatoryHumanEvenOnSharedBranch() {
        // Fast-forward push is not destructive: ask, never deny, on main.
        let verdict = ActionPolicyEngine.evaluate(
            action: ActionPolicyFixtures.plainPush(branchName: "main"),
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(verdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func plainPush_unknownRef_isMandatoryHumanNotReviewEligible() {
        // No allow arm for remote mutation: unknown refs fail toward Ask.
        for world in [
            GitAnalysisWorld.unprobed,
            .probed(GitAnalysisContext(currentBranch: "main")),
        ] {
            let verdict = ActionPolicyEngine.evaluate(
                action: ActionPolicyFixtures.plainPush(branchName: nil),
                context: shared,
                gitWorld: world
            )
            #expect(verdict.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
        }
    }

    @Test func overlayAllow_cannotWeakenBuiltInHardZones() {
        let action = ActionPolicyFixtures.forcePush()
        let overlay = EffectiveActionPolicy(overlay: .allow)
        let denied = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: overlay,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        let asked = ActionPolicyEngine.evaluate(
            action: ActionPolicyFixtures.forcePush(branchName: "topic"),
            context: privateBranch,
            policy: overlay,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: privateBranch)
        )
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(asked.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func probedCurrentBranch_mainIsShared_featureIsNot() {
        let implicit = ActionPolicyFixtures.implicitForcePush()
        let onMain = ActionPolicyEngine.evaluate(
            action: implicit,
            context: privateBranch,
            gitWorld: .probed(GitAnalysisContext(currentBranch: "main"))
        )
        #expect(onMain.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))

        let onFeature = ActionPolicyEngine.evaluate(
            action: implicit,
            context: privateBranch,
            gitWorld: .probed(GitAnalysisContext(currentBranch: "feature"))
        )
        #expect(onFeature.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk))
    }

    @Test func unprobed_ignoresRepositoryIsSharedBranch() {
        let topic = ActionPolicyFixtures.forcePush(branchName: "topic")
        let unprobedTopic = ActionPolicyEngine.evaluate(
            action: topic,
            context: shared,
            gitWorld: .unprobed
        )
        #expect(
            unprobedTopic.decision == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
        )

        let probedTopic = ActionPolicyEngine.evaluate(
            action: topic,
            context: shared,
            gitWorld: .probed(GitAnalysisContext(currentBranch: "main"))
        )
        #expect(probedTopic.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))

        let probedWorldPrivateContext = ActionPolicyEngine.evaluate(
            action: topic,
            context: privateBranch,
            gitWorld: .probed(GitAnalysisContext(currentBranch: "main"))
        )
        #expect(
            probedWorldPrivateContext.decision
                == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch)
        )

        let implicit = ActionPolicyFixtures.implicitForcePush()
        let unprobedImplicit = ActionPolicyEngine.evaluate(
            action: implicit,
            context: shared,
            gitWorld: .unprobed
        )
        #expect(
            unprobedImplicit.decision
                == .reviewEligible(fallback: ActionPolicyEngine.Builtin.uncovered)
        )

        let probedImplicit = ActionPolicyEngine.evaluate(
            action: implicit,
            context: shared,
            gitWorld: .probed(GitAnalysisContext(currentBranch: "main"))
        )
        #expect(probedImplicit.decision == .hardDeny(ActionPolicyEngine.Builtin.remoteSharedBranch))
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
        let createVerdict = ActionPolicyEngine.evaluate(
            action: create,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        let discardVerdict = ActionPolicyEngine.evaluate(
            action: discard,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )

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
            ActionPolicyEngine.evaluate(
                action: create,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision
                == .hardAllow
        )
        #expect(
            ActionPolicyEngine.evaluate(
                action: discard,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision
                == .hardDeny(ActionPolicyEngine.Builtin.workingTreeDiscard)
        )
        #expect(
            ActionPolicyEngine.evaluate(
                action: labelledCreate,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision
                == ActionPolicyEngine.evaluate(
                    action: create,
                    context: shared,
                    gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
                ).decision
        )
        #expect(
            ActionPolicyEngine.evaluate(
                action: labelledDiscard,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision
                == ActionPolicyEngine.evaluate(
                    action: discard,
                    context: shared,
                    gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
                ).decision
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
            policy: EffectiveActionPolicy(packFallback: .deny(packDeny)),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
            policy: EffectiveActionPolicy(packFallback: .ask(packAsk)),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
            policy: packAllow,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
        let verdict = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(verdict.decision == .reviewEligible(fallback: ActionPolicyEngine.Builtin.uncovered))
        #expect(verdict.explanation.zone == .reviewEligible)
    }

    @Test func protectedScopeWrite_withoutMutationEffect_isStillHardDeny() {
        let action = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite],
            path: "/home/.ssh/id_rsa",
            scope: .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
        let denied = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.protectedPath))
        let overlay = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .allow),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(overlay.decision == .hardDeny(ActionPolicyEngine.Builtin.protectedPath))
    }

    @Test func overlayAllow_cannotLiftProtectedPathMutation() {
        let action = ActionPolicyFixtures.filesystem(
            effects: [.filesystemDelete, .protectedPathMutation],
            path: "/home/.ssh/id_rsa",
            scope: .protectedPath(SecretPathMatch(pattern: "id-rsa", category: .ssh))
        )
        let denied = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.protectedPath))
        let overlay = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .allow),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
        #expect(
            ActionPolicyEngine.evaluate(
                action: write,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision == .hardAllow
        )
        #expect(
            ActionPolicyEngine.evaluate(
                action: create,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision == .hardAllow
        )
        #expect(
            ActionPolicyEngine.evaluate(
                action: write,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).explanation.ruleID
                == ActionPolicyEngine.Builtin.inRepository
        )
        let overlayDeny = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "repo.policy"), pattern: "no-source-writes"),
            reason: "Repository policy forbids source writes."
        )
        let tightened = ActionPolicyEngine.evaluate(
            action: write,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .deny(overlayDeny)),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
        let denied = ActionPolicyEngine.evaluate(
            action: write,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository))
        #expect(
            ActionPolicyEngine.evaluate(
                action: delete,
                context: shared,
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision
                == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository)
        )
        let overlay = ActionPolicyEngine.evaluate(
            action: write,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .allow),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
        let allowed = ActionPolicyEngine.evaluate(
            action: read,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(allowed.decision == .hardAllow)
        #expect(allowed.explanation.ruleID == ActionPolicyEngine.Builtin.outsideRepositoryRead)
        let overlayDeny = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "repo.policy"), pattern: "no-outside-reads"),
            reason: "Repository policy forbids outside reads."
        )
        let tightened = ActionPolicyEngine.evaluate(
            action: read,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .deny(overlayDeny)),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
                policy: EffectiveActionPolicy(overlay: .deny(overlayDeny)),
                gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
            ).decision == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository)
        )
    }

    @Test func unresolvedFilesystem_isFailClosed() {
        let unknown = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite, .unresolvedFilesystem],
            path: "/gone/file",
            scope: .unknown
        )
        let denied = ActionPolicyEngine.evaluate(
            action: unknown,
            context: shared,
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(denied.decision == .hardDeny(ActionPolicyEngine.Builtin.unresolvedFilesystem))
        let overlay = ActionPolicyEngine.evaluate(
            action: unknown,
            context: shared,
            policy: EffectiveActionPolicy(overlay: .allow),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
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
            policy: EffectiveActionPolicy(overlay: .deny(overlayDeny)),
            gitWorld: ActionPolicyFixtures.probedGitWorld(for: shared)
        )
        #expect(verdict.decision == .hardDeny(overlayDeny))
    }

    @Test func filesystemWorlds_unresolvedOnly_probedDeniesUnprobedDefersToPackFloor() {
        let unknown = ActionPolicyFixtures.filesystem(
            effects: [.filesystemOverwrite, .unresolvedFilesystem],
            path: "/gone/file",
            scope: .unknown
        )
        let probed = ActionPolicyEngine.evaluate(
            action: unknown,
            context: shared,
            gitWorld: .unprobed,
            filesystemWorld: .probed(.empty)
        )
        #expect(probed.decision == .hardDeny(ActionPolicyEngine.Builtin.unresolvedFilesystem))

        let unprobed = ActionPolicyEngine.evaluate(
            action: unknown,
            context: shared,
            gitWorld: .unprobed,
            filesystemWorld: .unprobed
        )
        #expect(
            unprobed.decision
                == .reviewEligible(fallback: ActionPolicyEngine.Builtin.uncovered)
        )
    }

    @Test func filesystemWorlds_unresolvedPlusOutside_probedRanksUnresolvedUnprobedRanksBoundary() {
        let mixed = ActionPolicyFixtures.filesystem(
            effects: [.filesystemDelete, .outsideRepositoryMutation, .unresolvedFilesystem],
            path: "/gone/file",
            scope: .unknown
        )
        let probed = ActionPolicyEngine.evaluate(
            action: mixed,
            context: shared,
            gitWorld: .unprobed,
            filesystemWorld: .probed(.empty)
        )
        #expect(probed.decision == .hardDeny(ActionPolicyEngine.Builtin.unresolvedFilesystem))

        let unprobed = ActionPolicyEngine.evaluate(
            action: mixed,
            context: shared,
            gitWorld: .unprobed,
            filesystemWorld: .unprobed
        )
        #expect(unprobed.decision == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository))
    }

    @Test func filesystemWorlds_protectedMutation_deniesInBothWorlds() {
        let protected = ActionPolicyFixtures.filesystem(
            effects: [.filesystemDelete, .protectedPathMutation, .unresolvedFilesystem],
            path: "/home/.ssh/id_rsa",
            scope: .unknown
        )
        for world in [FilesystemAnalysisWorld.probed(.empty), .unprobed] {
            let verdict = ActionPolicyEngine.evaluate(
                action: protected,
                context: shared,
                gitWorld: .unprobed,
                filesystemWorld: world
            )
            #expect(verdict.decision == .hardDeny(ActionPolicyEngine.Builtin.protectedPath))
        }
    }

    @Test func filesystemWorlds_analyzedMixedTargets_rankPerWorld() {
        // Real IR behind the Apply door: one resolved outside target and one
        // unresolved target. Probed ranks unresolved first; unprobed lets
        // the boundary hit deny instead of masking it.
        let mixed = FilesystemAction.delete(
            targets: [
                FilesystemTarget(
                    apparent: "../outside-file",
                    canonical: "/outside-file",
                    scope: .outsideRepository,
                    kind: .unknown
                ),
                FilesystemTarget(
                    apparent: "file",
                    canonical: "/repo/file",
                    scope: .unknown,
                    kind: .unknown
                ),
            ],
            recursive: false,
            force: false
        )
        let action = mixed.proposedAction(
            command: ShellCommand(rawValue: "rm file ../outside-file"),
            workingDirectory: nil
        )
        let probed = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            gitWorld: .unprobed,
            filesystemWorld: .probed(.empty)
        )
        #expect(probed.decision == .hardDeny(ActionPolicyEngine.Builtin.unresolvedFilesystem))

        let unprobed = ActionPolicyEngine.evaluate(
            action: action,
            context: shared,
            gitWorld: .unprobed,
            filesystemWorld: .unprobed
        )
        #expect(unprobed.decision == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository))
    }
}
