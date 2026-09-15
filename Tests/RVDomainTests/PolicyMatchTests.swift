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
