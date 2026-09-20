import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplySemanticsDoor")
struct ApplySemanticsDoorTests {
    @Test func leftoverApplyGit_wrappedResetHard_matchesDoorAnalysis() throws {
        let command = "bash -c 'git reset --hard'"
        let pack = try runSemanticsPack(command)
        let leftover = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        let door = try runSemanticsDoor(command)

        #expect(leftover.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
        #expect(leftover.analysis.wrappers == [.bash])
        #expect(leftover.analysis == door.analysis)
        #expect(leftover.decision == door.decision)
    }

    @Test func leftoverApplyFilesystem_wrappedRm_matchesDoorDecisionAndInnermost() throws {
        let command = "bash -c 'rm /tmp/rv-engine-door-test'"
        let filesystemWorld = FilesystemAnalysisWorld.probed(
            FilesystemAnalysisContext(
                workingDirectory: WorkingDirectory(validating: "/repo"),
                repositoryRoot: RepositoryRoot(validating: "/repo")
            )
        )
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)

        let leftover = applyFilesystemSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            filesystemWorld: filesystemWorld
        )
        let door = try runSemanticsDoor(command, filesystemProbe: { _ in filesystemWorld })

        #expect(leftover.decision == door.decision)
        #expect(leftover.analysis.innermost == door.analysis.innermost)
        guard case .deny = leftover.decision else {
            Issue.record("probed out-of-repo rm must deny, got \(leftover.decision)")
            return
        }
    }
}
