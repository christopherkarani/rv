import Testing
import RVDomain

@Suite("PolicyMatch")
struct PolicyMatchTests {
    private let forceMain = PolicyPredicate.gitPush(force: .force, branch: "main")

    @Test func forceMain_matchesGitPushForceMain() {
        let git = forcePush(refspec: "main")
        #expect(git.resources.branchName == "main")
        #expect(PolicyMatch.matches(forceMain, action: git))
        #expect(PolicyMatch.matches(forceMain, action: proposed(git)))
    }

    @Test func forceMain_doesNotMatchFeatureBranch() {
        let git = forcePush(refspec: "feature")
        #expect(git.resources.branchName == "feature")
        #expect(PolicyMatch.matches(forceMain, action: git) == false)
        #expect(PolicyMatch.matches(forceMain, action: proposed(git)) == false)
    }

    @Test func forceMain_doesNotReadSupportingCommand() {
        let feature = proposed(
            forcePush(refspec: "feature"),
            command: "git push --force origin main"
        )
        #expect(feature.supportingCommand?.rawValue == "git push --force origin main")
        #expect(PolicyMatch.matches(forceMain, action: feature) == false)

        let main = proposed(
            forcePush(refspec: "main"),
            command: "git push --force origin feature"
        )
        #expect(main.supportingCommand?.rawValue == "git push --force origin feature")
        #expect(PolicyMatch.matches(forceMain, action: main))
    }

    @Test(arguments: ["main", "HEAD:main", "refs/heads/main", "+main"])
    func forceMain_matchesRefspecThatNamesMain(_ refspec: String) {
        let git = forcePush(refspec: refspec)
        #expect(PolicyMatch.matches(forceMain, action: git))
        #expect(PolicyMatch.matches(forceMain, action: proposed(git)))
    }

    @Test(arguments: ["feature", "HEAD:feature", "refs/heads/feature", "main:feature"])
    func forceMain_doesNotMatchRefspecThatNamesFeature(_ refspec: String) {
        let git = forcePush(refspec: refspec)
        #expect(PolicyMatch.matches(forceMain, action: git) == false)
        #expect(PolicyMatch.matches(forceMain, action: proposed(git)) == false)
    }

    @Test func gitPush_doesNotMatchNonPushGitAction() {
        let reset = GitAction.reset(mode: .hard, target: nil)
        #expect(PolicyMatch.matches(forceMain, action: reset) == false)
        #expect(PolicyMatch.matches(forceMain, action: proposed(reset)) == false)
    }

    @Test func forceMain_matchesProposedActionFromResourcesAndEffects() {
        let action = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:git.force-push:origin:main"),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(remoteName: "origin", branchName: "main"),
                supportingCommand: ShellCommand(rawValue: "git push --force origin feature")
            )
        )
        #expect(PolicyMatch.matches(forceMain, action: action))
    }
}

private func forcePush(refspec: String) -> GitAction {
    .push(remote: "origin", refspec: refspec, force: .force, delete: false)
}

private func proposed(_ git: GitAction, command: String = "git status") -> ProposedAction {
    git.proposedAction(
        command: ShellCommand(rawValue: command),
        workingDirectory: WorkingDirectory(validating: "/tmp/rv")
    )
}
