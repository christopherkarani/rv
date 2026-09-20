import Foundation
import Testing
@testable import RVDomain

struct LinuxResidualCoverageTests {
    @Test func matchingView_rawValueInitAndDescription() {
        let view = MatchingView(rawValue: "git status")
        #expect(view.rawValue == "git status")
        #expect(view.description == "git status")
        #expect(view.isEmpty == false)
    }

    @Test func fakeCompiler_refusesGitStatusAndNpmAndMcp() async throws {
        let compiler = FakeEnglishCompiler()
        #expect(try await compiler.compile("git status") == .refuse(.unsupportedPredicate))
        #expect(try await compiler.compile("npm publish") == .refuse(.unsupported))
        #expect(try await compiler.compile("mcp__linear__save_issue") == .refuse(.unsupported))
    }

    @Test func coding_rejectsInvalidRuleIDAndUnknownDecision() throws {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RuleID.self, from: Data(#""not-a-rule""#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Decision.self, from: Data(#"{"decision":"maybe"}"#.utf8))
        }
    }

    @Test func boundReviewAllow_projectsAllowDecision() {
        #expect(BoundReview.allow.decision == .allow)
    }

    @Test func liveEvaluation_exposesOutcomeDecision() {
        let live = LiveEvaluation(
            outcome: .plain,
            matchingView: MatchingView("echo ok"),
            analysis: .unknown,
            bound: .allow
        )
        #expect(live.decision == .allow)
        #expect(live.result.decision == .allow)
    }

    @Test func proposedActionFile_hasNoGitAction() {
        let file = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:claude:::read:/tmp/a.md"),
                file: FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/a.md"))
            )
        )
        #expect(file.gitAction == nil)
        #expect(file.supportingCommand == nil)
    }

    @Test func hostNativeAsk_recordsPendingAndIndeterminateMandatoryStayDeny() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let deny = Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "destroys uncommitted changes"
        )
        let denied = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        let allowedBind = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .allow
        )
        let human = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        #expect(HostNativeAsk.recordsPending(result: allowedBind, cwd: cwd) == false)
        #expect(HostNativeAsk.recordsPending(result: denied, cwd: cwd))
        #expect(HostNativeAsk.recordsPending(result: human, cwd: cwd))
        let indeterminate = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView("huge"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        #expect(
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: indeterminate,
                cwd: cwd
            ) == .deny
        )
    }

    @Test func gitAction_explainAndFingerprintResiduals() {
        let soft = GitAction.reset(mode: .soft, target: "HEAD")
        #expect(soft.effectScope == .localIndex)
        #expect(soft.explainAction == "reset --soft")
        #expect(soft.explainRef == "HEAD")

        let forceCreate = GitAction.createBranch(name: "topic", startPoint: nil, force: true)
        #expect(forceCreate.explainAction == "force branch create/reset")
        #expect(forceCreate.proposedAction(
            command: ShellCommand(rawValue: "git checkout -B topic"),
            workingDirectory: nil
        ).gitAction == forceCreate)

        let switched = GitAction.switchBranch(name: "main", force: true)
        #expect(switched.explainAction == "branch switch")
        #expect(switched.effects.kinds == [.workingTreeDiscard])

        let dry = GitAction.clean(force: false, dryRun: true, directories: false)
        #expect(dry.explainAction == "clean dry-run")
        let forcedClean = GitAction.clean(force: true, dryRun: false, directories: true)
        #expect(forcedClean.explainAction == "clean force")
        let quietClean = GitAction.clean(force: false, dryRun: false, directories: false)
        #expect(quietClean.explainAction == "clean")

        let lease = GitAction.push(remote: "origin", refspec: "topic", force: .forceWithLease)
        #expect(lease.explainAction == "force-push with lease")

        let tag = GitAction.deleteTag(name: "v1", remote: "origin")
        #expect(tag.explainAction == "tag delete")
        #expect(tag.resources.remoteName == "origin")
        #expect(tag.resources.branchName == "v1")

        let stash = GitAction.stash(verb: .drop)
        #expect(stash.explainAction == "stash drop")
        #expect(stash.explainScope == "local")

        let abort = GitAction.rebase(verb: .abort, onto: nil)
        #expect(abort.explainAction == "rebase abort")
        let cont = GitAction.rebase(verb: .continueRebase, onto: "main")
        #expect(cont.explainAction == "rebase continue")
        #expect(cont.explainRef == "main")
        let skip = GitAction.rebase(verb: .skip, onto: nil)
        #expect(skip.explainAction == "rebase skip")
        let start = GitAction.rebase(verb: .start, onto: "onto")
        #expect(start.explainAction == "rebase")

        let deleteBranch = GitAction.deleteBranch(name: "old", force: false)
        #expect(deleteBranch.explainAction == "branch delete")
        _ = deleteBranch.proposedAction(
            command: ShellCommand(rawValue: "git branch -d old"),
            workingDirectory: nil
        )
        _ = GitAction.discardWorktree(pathspecs: ["a"], source: "HEAD").proposedAction(
            command: ShellCommand(rawValue: "git checkout HEAD -- a"),
            workingDirectory: nil
        )
    }

    @Test func filesystemAction_scopeLabelsAndMoveChmodRead() {
        let inside = FilesystemTarget(
            apparent: "a",
            canonical: "/repo/a",
            scope: .insideRepository,
            kind: .sourceCode
        )
        let outside = FilesystemTarget(
            apparent: "b",
            canonical: "/tmp/b",
            scope: .outsideRepository,
            kind: .generatedOutput
        )
        let unknown = FilesystemTarget(
            apparent: "c",
            canonical: "/c",
            scope: .unknown,
            kind: .unknown
        )
        #expect(FilesystemScope.outsideRepository.rawValue == "outsideRepository")
        #expect(FilesystemScope.unknown.rawValue == "unknown")

        let moved = FilesystemAction.move(sources: [inside], destination: outside)
        #expect(moved.explainAction == "move")
        #expect(moved.targets.count == 2)
        #expect(moved.effects.kinds.contains(.filesystemMove))
        _ = moved.proposedAction(
            command: ShellCommand(rawValue: "mv a /tmp/b"),
            workingDirectory: nil
        )

        let chmod = FilesystemAction.chmod(targets: [inside], mode: "755", recursive: false)
        #expect(chmod.explainAction == "chmod")
        #expect(chmod.effects.kinds.contains(.filesystemModeChange))
        _ = chmod.proposedAction(
            command: ShellCommand(rawValue: "chmod 755 a"),
            workingDirectory: nil
        )

        let read = FilesystemAction.read(targets: [unknown])
        #expect(read.explainAction == "read")
        #expect(read.explainScope == "unknown")
        #expect(read.effects.kinds.contains(.filesystemRead))
    }

    @Test func gitPushForceConstraint_encodesAnyAndExact() throws {
        let any = try JSONEncoder().encode(GitPushForceConstraint.any)
        #expect(String(data: any, encoding: .utf8) == "null")
        #expect(try JSONDecoder().decode(GitPushForceConstraint.self, from: any) == .any)
        let exact = try JSONEncoder().encode(GitPushForceConstraint.exactly(.force))
        #expect(try JSONDecoder().decode(GitPushForceConstraint.self, from: exact) == .exactly(.force))
    }

    @Test func policyMatch_rejectsMismatchedCleanAndDelete() {
        let clean = GitAction.clean(force: true, dryRun: false, directories: false)
        #expect(PolicyMatch.matches(.gitClean(force: false, directories: nil), action: clean) == false)
        #expect(PolicyMatch.matches(.gitClean(force: true, directories: true), action: clean) == false)

        let delete = FilesystemAction.delete(
            targets: [
                FilesystemTarget(
                    apparent: "a",
                    canonical: "/repo/a",
                    scope: .insideRepository,
                    kind: .sourceCode
                ),
            ],
            recursive: true,
            force: false
        )
        #expect(
            PolicyMatch.matches(.filesystemDelete(recursive: false, force: nil), action: delete)
                == false
        )
        #expect(
            PolicyMatch.matches(.filesystemDelete(recursive: true, force: true), action: delete)
                == false
        )
        #expect(PolicyMatch.matches(.filesystemDelete(recursive: nil, force: nil), action: clean) == false)
    }

    @Test func pendingApprovalState_expiredRoundTripAndUnknownKind() throws {
        let state = PendingApprovalState.expired(at: Date(timeIntervalSince1970: 10))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(PendingApprovalState.self, from: data) == state)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                PendingApprovalState.self,
                from: Data(#"{"kind":"mystery"}"#.utf8)
            )
        }
    }

    @Test func hardPolicyDecision_zonesAndCodable() throws {
        let deny = Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
        #expect(HardPolicyDecision.hardAllow.zone == .hardAllow)
        #expect(HardPolicyDecision.hardDeny(deny).zone == .hardDeny)
        #expect(HardPolicyDecision.mandatoryHuman(deny).zone == .mandatoryHuman)
        #expect(HardPolicyDecision.reviewEligible(fallback: deny).zone == .reviewEligible)
        for zone in [ActionPolicyZone.hardAllow, .mandatoryHuman, .hardDeny, .reviewEligible] {
            let data = try JSONEncoder().encode(zone)
            #expect(try JSONDecoder().decode(ActionPolicyZone.self, from: data) == zone)
        }
        let verdict = HardPolicyDecision.reviewEligible(fallback: deny)
        #expect(try JSONDecoder().decode(HardPolicyDecision.self, from: JSONEncoder().encode(verdict)) == verdict)
    }

    @Test func liveEvaluation_attachesPackProjectionAndWireStripBound() {
        let deny = Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x")
        let unbound = EvaluationResult(outcome: .plain, matchingView: MatchingView("echo"))
        #expect(LiveEvaluation(unbound).bound == .allow)
        let bound = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("echo"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(deny)
        )
        let live = LiveEvaluation(bound)
        #expect(live.bound == .mandatoryHuman(deny))
        #expect(live.wire.boundReview == nil)
        #expect(bound.wire.boundReview == nil)
    }

    @Test func evaluationOutcome_composingResidualsAndDecodeErrorText() {
        let match = RuleMatch(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            severity: .critical,
            reason: "x"
        )
        let safe = SafeMatch(packID: .coreGit, patternName: "keep")
        #expect(throws: EvaluationResultDecodingError.self) {
            _ = try EvaluationOutcome.composing(
                decision: .allow,
                matched: match,
                matchedSafe: nil,
                quickRejected: true
            )
        }
        #expect(throws: EvaluationResultDecodingError.self) {
            _ = try EvaluationOutcome.composing(
                decision: .deny(Deny(ruleID: match.ruleID, reason: "x")),
                matched: match,
                matchedSafe: safe,
                quickRejected: false
            )
        }
        #expect(throws: EvaluationResultDecodingError.self) {
            _ = try EvaluationOutcome.composing(
                decision: .indeterminate(.commandTooLarge),
                matched: match,
                matchedSafe: nil,
                quickRejected: false
            )
        }
        let error = EvaluationResultDecodingError(
            decision: .allow,
            matchedPresent: true,
            matchedSafePresent: false,
            quickRejected: true
        )
        #expect(error.description.contains("impossible EvaluationResult"))
        #expect(error.description.contains("matched=true"))
    }

    @Test func pendingAction_usesFilesystemEffectsWhenGitAbsent() {
        let fs = FilesystemAction.read(
            targets: [
                FilesystemTarget(
                    apparent: "a",
                    canonical: "/repo/a",
                    scope: .insideRepository,
                    kind: .sourceCode
                ),
            ]
        )
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("cat a"),
            analysis: .filesystem(fs)
        )
        let action = result.pendingAction(
            host: .pi,
            session: SessionID(validating: "sess"),
            cwd: WorkingDirectory(validating: "/tmp/ws"),
            command: ShellCommand(rawValue: "cat a")
        )
        #expect(action.gitAction == nil)
        #expect(action.effects.kinds.contains(.filesystemRead))
        #expect(action.resources.filesystemScope == .insideRepository)
        guard case .shell(let shell) = action else {
            Issue.record("expected shell pending action")
            return
        }
        #expect(shell.filesystemAction == fs)
    }

    @Test func englishCompileRefusal_andPackFallbackIndeterminate() throws {
        for refusal in [
            EnglishCompileRefusal.empty,
            .uncompilable,
            .unsupported,
            .unsupportedPredicate,
            .hardStop,
        ] {
            let data = try JSONEncoder().encode(refusal)
            #expect(try JSONDecoder().decode(EnglishCompileRefusal.self, from: data) == refusal)
        }
        let incomplete = EvaluationResult(
            outcome: .indeterminate(.corePacksUnavailable),
            matchingView: MatchingView("x")
        )
        #expect(PackFallback(incomplete) == .deny(ActionPolicyEngine.Builtin.packIncomplete))
    }

    @Test func filesystemScope_protectedPathAndActionResiduals() {
        let match = SecretPathMatch(pattern: ".env", category: .environment)
        let protected = FilesystemScope.protectedPath(match)
        #expect(protected.rawValue == "protectedPath")
        #expect(protected.protectedMatch == match)
        let target = FilesystemTarget(
            apparent: ".env",
            canonical: "/tmp/.env",
            scope: protected,
            kind: .unknown
        )
        #expect(target.protectedMatch == match)
        let overwrite = FilesystemAction.overwrite(targets: [target])
        #expect(overwrite.explainAction == "overwrite")
        #expect(overwrite.effects.kinds.contains(.filesystemOverwrite))
        let created = FilesystemAction.create(targets: [target])
        #expect(created.explainAction == "create")
        #expect(created.effects.kinds.contains(.filesystemCreate))
    }

    @Test func actionPolicyEngine_filesystemHitResiduals() {
        let inside = ActionResources(filesystemScope: .insideRepository)
        let outside = ActionResources(filesystemScope: .outsideRepository)
        let protected = ActionResources(
            filesystemScope: .protectedPath(SecretPathMatch(pattern: "id_ed25519", category: .ssh))
        )
        let writeInside = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "fs-inside"),
                effects: ActionEffects(kinds: [.filesystemOverwrite]),
                resources: inside
            )
        )
        #expect(
            ActionPolicyEngine.evaluate(action: writeInside).decision == .hardAllow
        )
        let writeOutside = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "fs-out"),
                effects: ActionEffects(kinds: [.filesystemCreate]),
                resources: outside
            )
        )
        #expect(
            ActionPolicyEngine.evaluate(action: writeOutside).decision
                == .hardDeny(ActionPolicyEngine.Builtin.outsideRepository)
        )
        let writeProtected = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "fs-prot"),
                effects: ActionEffects(kinds: [.filesystemDelete]),
                resources: protected
            )
        )
        #expect(
            ActionPolicyEngine.evaluate(action: writeProtected).decision
                == .hardDeny(ActionPolicyEngine.Builtin.protectedPath)
        )
        let request = ReviewRequest(
            action: writeInside,
            context: ReviewContext(repository: RepositoryReviewContext())
        )
        #expect(ActionPolicyEngine.evaluate(request).decision == .hardAllow)
    }

    @Test func boundReview_packProjectedIndeterminateIsAllow() {
        let incomplete = EvaluationResult(
            outcome: .indeterminate(.budgetExhausted),
            matchingView: MatchingView("huge")
        )
        #expect(BoundReview.packProjected(from: incomplete) == .allow)
    }
}
