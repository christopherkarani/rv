import Testing
import RVDomain

@Suite("GitAction")
struct GitActionTests {
    @Test func createAndDiscard_mapToDistinctEffects() {
        let create = GitAction.createBranch(name: "feature", startPoint: nil, force: false)
        let discard = GitAction.discardWorktree(pathspecs: ["file.swift"], source: nil)
        #expect(create.effects.kinds == [.localBranchCreate])
        #expect(discard.effects.kinds == [.workingTreeDiscard])
        #expect(create.explainAction == "branch creation")
        #expect(discard.explainAction == "working-tree overwrite/discard")
    }

    @Test func pushForce_isHigherImpactThanNormalPush() {
        let normal = GitAction.push(
            remote: "origin",
            refspec: "feature",
            force: .none
        )
        let forced = GitAction.push(
            remote: "origin",
            refspec: "main",
            force: .force
        )
        #expect(normal.effects.kinds.isEmpty)
        #expect(forced.effects.kinds == [.remoteSharedBranchMutation])
        #expect(normal.effectScope == .remote)
        #expect(forced.effectScope == .remote)
        #expect(normal.explainAction == "push")
        #expect(forced.explainAction == "force-push")
    }

    @Test func deleteRemoteRef_isRemoteMutationNotPush() {
        let deleted = GitAction.deleteRemoteRef(remote: "origin", refspec: "topic")
        #expect(deleted.effects.kinds == [.remoteSharedBranchMutation])
        #expect(deleted.effectScope == .remote)
        #expect(deleted.explainAction == "remote ref delete")
        #expect(deleted.resources.branchName == "topic")
        let proposed = deleted.proposedAction(
            command: ShellCommand(rawValue: "git push origin :topic"),
            workingDirectory: WorkingDirectory(validating: "/tmp/rv")
        )
        #expect(proposed.gitAction == deleted)
    }

    @Test func proposedAction_carriesEffectsNotCommandText() {
        let action = GitAction.createBranch(name: "feature", startPoint: nil, force: false)
        let proposed = action.proposedAction(
            command: ShellCommand(rawValue: "git checkout -- file.swift"),
            workingDirectory: WorkingDirectory(validating: "/tmp/rv")
        )
        #expect(proposed.effects.kinds == [.localBranchCreate])
        #expect(proposed.resources.branchName == "feature")
        #expect(proposed.supportingCommand?.rawValue == "git checkout -- file.swift")
    }
}
