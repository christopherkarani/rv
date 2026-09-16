import Testing
import RVDomain

@Suite("PolicyMatch")
struct PolicyMatchTests {
    private let forceMain = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")

    @Test func forceMain_matchesGitPushForceMain() {
        let git = forcePush(refspec: "main")
        #expect(git.resources.branchName == "main")
        #expect(PolicyMatch.matches(forceMain, action: git))
    }

    @Test func forceMain_doesNotMatchFeatureBranch() {
        let git = forcePush(refspec: "feature")
        #expect(git.resources.branchName == "feature")
        #expect(PolicyMatch.matches(forceMain, action: git) == false)
    }

    @Test func forceMain_doesNotReadSupportingCommand() {
        let feature = forcePush(refspec: "feature")
        let featureCommand = proposed(feature, command: "git push --force origin main")
        #expect(featureCommand.supportingCommand?.rawValue == "git push --force origin main")
        #expect(PolicyMatch.matches(forceMain, action: feature) == false)

        let main = forcePush(refspec: "main")
        let mainCommand = proposed(main, command: "git push --force origin feature")
        #expect(mainCommand.supportingCommand?.rawValue == "git push --force origin feature")
        #expect(PolicyMatch.matches(forceMain, action: main))
    }

    @Test(arguments: ["main", "HEAD:main", "refs/heads/main", "+main"])
    func forceMain_matchesRefspecThatNamesMain(_ refspec: String) {
        let git = forcePush(refspec: refspec)
        #expect(PolicyMatch.matches(forceMain, action: git))
    }

    @Test(arguments: ["feature", "HEAD:feature", "refs/heads/feature", "main:feature"])
    func forceMain_doesNotMatchRefspecThatNamesFeature(_ refspec: String) {
        let git = forcePush(refspec: refspec)
        #expect(PolicyMatch.matches(forceMain, action: git) == false)
    }

    @Test func gitPush_doesNotMatchNonPushGitAction() {
        let reset = GitAction.reset(mode: .hard, target: nil)
        #expect(PolicyMatch.matches(forceMain, action: reset) == false)
    }

    @Test func gitPush_doesNotMatchDeleteRemoteRef() {
        let deleted = GitAction.deleteRemoteRef(remote: "origin", refspec: "topic")
        let anyPush = PolicyPredicate.gitPush(force: .any, branch: nil)
        #expect(PolicyMatch.matches(anyPush, action: deleted) == false)
        #expect(PolicyMatch.matches(anyPush, action: forcePush(refspec: "topic")))
        #expect(PolicyMatch.matches(forceMain, action: deleted) == false)
        #expect(
            PolicyMatch.matches(
                .gitPush(force: .any, branch: "topic"),
                action: GitAction.deleteRemoteRef(remote: "origin", refspec: "topic")
            ) == false
        )
    }

    @Test func gitPush_doesNotMatchNonForceSwitchBranch() {
        let switched = GitAction.switchBranch(name: "main", force: false)
        #expect(PolicyMatch.matches(.gitPush(force: .any, branch: "main"), action: switched) == false)
        #expect(
            PolicyMatch.matches(.gitPush(force: .exactly(.none), branch: "main"), action: switched)
                == false
        )
        #expect(PolicyMatch.matches(forceMain, action: switched) == false)
    }

    @Test func forceMain_doesNotMatchForceWithLease() {
        let leased = GitAction.push(
            remote: "origin",
            refspec: "main",
            force: .forceWithLease
        )
        #expect(PolicyMatch.matches(forceMain, action: leased) == false)
    }

    @Test func gitPushForceAny_matchesForceAndNonForceMainNotFeature() {
        let anyMain = PolicyPredicate.gitPush(force: .any, branch: "main")
        #expect(PolicyMatch.matches(anyMain, action: forcePush(refspec: "main")))
        #expect(PolicyMatch.matches(anyMain, action: push(refspec: "main", force: .none)))
        #expect(PolicyMatch.matches(anyMain, action: forcePush(refspec: "feature")) == false)
        #expect(PolicyMatch.matches(anyMain, action: push(refspec: "feature", force: .none)) == false)
    }

    @Test func gitPushForceExactlyNone_matchesNonForceMainNotForce() {
        let noneMain = PolicyPredicate.gitPush(force: .exactly(.none), branch: "main")
        #expect(PolicyMatch.matches(noneMain, action: push(refspec: "main", force: .none)))
        #expect(PolicyMatch.matches(noneMain, action: forcePush(refspec: "main")) == false)
    }

    @Test func gitPushForceAny_matchesForcePushToMain_exactlyNoneDoesNot() {
        let forcePushToMain = forcePush(refspec: "main")
        #expect(PolicyMatch.matches(.gitPush(force: .any, branch: "main"), action: forcePushToMain))
        #expect(
            PolicyMatch.matches(.gitPush(force: .exactly(.none), branch: "main"), action: forcePushToMain)
                == false
        )
    }

    @Test func discardWorktree_matchesDiscardAndWorktreeRestore() {
        let any = PolicyPredicate.gitDiscardWorktree(pathspec: nil)
        let file = PolicyPredicate.gitDiscardWorktree(pathspec: "file.swift")
        let discard = GitAction.discardWorktree(pathspecs: ["file.swift"], source: nil)
        let restore = GitAction.restore(
            pathspecs: ["file.swift"],
            destination: .worktree,
            source: nil
        )
        #expect(PolicyMatch.matches(any, action: discard))
        #expect(PolicyMatch.matches(file, action: discard))
        #expect(PolicyMatch.matches(file, action: restore))
        #expect(
            PolicyMatch.matches(
                .gitDiscardWorktree(pathspec: "other.swift"),
                action: discard
            ) == false
        )
        #expect(
            PolicyMatch.matches(
                any,
                action: GitAction.restore(pathspecs: ["file.swift"], destination: .index, source: nil)
            ) == false
        )
        #expect(PolicyMatch.matches(any, action: GitAction.reset(mode: .hard, target: nil)) == false)
    }

    @Test func gitReset_matchesMode() {
        let any = PolicyPredicate.gitReset(mode: nil)
        let hard = PolicyPredicate.gitReset(mode: .hard)
        #expect(PolicyMatch.matches(any, action: .reset(mode: .soft, target: nil)))
        #expect(PolicyMatch.matches(hard, action: .reset(mode: .hard, target: "HEAD")))
        #expect(PolicyMatch.matches(hard, action: .reset(mode: .soft, target: nil)) == false)
        #expect(PolicyMatch.matches(any, action: forcePush(refspec: "main")) == false)
    }

    @Test func gitClean_matchesFlags() {
        let any = PolicyPredicate.gitClean(force: nil, directories: nil)
        let force = PolicyPredicate.gitClean(force: true, directories: nil)
        #expect(PolicyMatch.matches(any, action: .clean(force: false, dryRun: true, directories: false)))
        #expect(PolicyMatch.matches(force, action: .clean(force: true, dryRun: false, directories: true)))
        #expect(
            PolicyMatch.matches(force, action: .clean(force: false, dryRun: false, directories: false))
                == false
        )
    }

    @Test func filesystemDeleteAndMove_matchOnlyThoseActions() {
        let target = FilesystemTarget(
            apparent: "file.swift",
            canonical: "/repo/file.swift",
            scope: .insideRepository,
            kind: .sourceCode
        )
        let delete = FilesystemAction.delete(targets: [target], recursive: true, force: true)
        let move = FilesystemAction.move(sources: [target], destination: target)
        #expect(PolicyMatch.matches(.filesystemDelete(recursive: nil, force: nil), action: delete))
        #expect(PolicyMatch.matches(.filesystemDelete(recursive: true, force: true), action: delete))
        #expect(
            PolicyMatch.matches(.filesystemDelete(recursive: false, force: nil), action: delete)
                == false
        )
        #expect(PolicyMatch.matches(.filesystemMove, action: move))
        #expect(PolicyMatch.matches(.filesystemMove, action: delete) == false)
        #expect(
            PolicyMatch.matches(.filesystemDelete(recursive: nil, force: nil), action: forcePush(refspec: "main"))
                == false
        )
        #expect(
            PolicyMatch.matches(.gitPush(force: .exactly(.force), branch: "main"), action: delete)
                == false
        )
    }
}

private func forcePush(refspec: String) -> GitAction {
    push(refspec: refspec, force: .force)
}

private func push(refspec: String, force: GitPushForce) -> GitAction {
    .push(remote: "origin", refspec: refspec, force: force)
}

private func proposed(_ git: GitAction, command: String) -> ProposedAction {
    git.proposedAction(
        command: ShellCommand(rawValue: command),
        workingDirectory: WorkingDirectory(validating: "/tmp/rv")
    )
}
