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
        #expect(HostNativeAsk.recordsPending(result: denied, cwd: cwd, bound: .allow) == false)
        #expect(HostNativeAsk.recordsPending(result: denied, cwd: cwd, bound: .deny(deny)))
        #expect(
            HostNativeAsk.recordsPending(
                result: denied,
                cwd: cwd,
                bound: .mandatoryHuman(deny)
            )
        )
        let indeterminate = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView("huge")
        )
        #expect(
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: indeterminate,
                cwd: cwd,
                bound: .mandatoryHuman(deny)
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
}
