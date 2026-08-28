import Testing
import RVDomain
@testable import RVEngine

@Suite("AnalyzeSemantics")
struct AnalyzeSemanticsTests {
    private let repo = FilesystemAnalysisContext(
        workingDirectory: WorkingDirectory(validating: "/repo"),
        repositoryRoot: RepositoryRoot(validating: "/repo")
    )

    @Test func bashDashC_matchesDirectGitReset() {
        let direct = analyzeSemantics(ShellCommand(rawValue: "git reset --hard"))
        let wrapped = analyzeSemantics(ShellCommand(rawValue: "bash -c 'git reset --hard'"))
        #expect(direct == .git(.reset(mode: .hard, target: nil)))
        #expect(wrapped.innermost == direct)
        #expect(wrapped.wrappers == [.bash])
    }

    @Test func sudoEnvSh_innerGitDrivesSemantics() {
        let direct = analyzeSemantics(ShellCommand(rawValue: "git reset --hard"))
        let wrapped = analyzeSemantics(
            ShellCommand(rawValue: "sudo env FOO=bar sh -c 'git reset --hard'")
        )
        #expect(wrapped.innermost == direct)
        #expect(wrapped.wrappers == [.sudo, .env, .sh])
    }

    @Test func echoQuotedRm_isNotDelete() {
        let analysis = analyzeSemantics(
            ShellCommand(rawValue: "echo 'rm -rf /'"),
            filesystemContext: repo
        )
        #expect(analysis == .unknown)
        #expect(analysis.filesystemAction == nil)
    }

    @Test func pythonPrintRm_isNotDelete() {
        let analysis = analyzeSemantics(
            ShellCommand(rawValue: #"python -c "print('rm -rf /')""#),
            filesystemContext: repo
        )
        #expect(analysis.innermost == .unknown)
        #expect(analysis.filesystemAction == nil)
    }

    @Test func pythonOsSystem_surfacesFilesystemDelete() {
        let analysis = analyzeSemantics(
            ShellCommand(rawValue: #"python -c "os.system('rm -rf Sources')""#),
            filesystemContext: repo
        )
        #expect(analysis.wrappers == [.python])
        guard case .filesystem(.delete(_, let recursive, let force)) = analysis.innermost else {
            Issue.record("expected delete, got \(analysis)")
            return
        }
        #expect(recursive && force)
    }

    @Test func nodeExecSync_surfacesGitReset() {
        let analysis = analyzeSemantics(
            ShellCommand(
                rawValue: #"node -e "require('child_process').execSync('git reset --hard')""#
            )
        )
        #expect(analysis.wrappers == [.node])
        #expect(analysis.innermost == .git(.reset(mode: .hard, target: nil)))
    }

    @Test func leafAnalyzers_stillLeaveBashDashCUnknown() {
        #expect(analyzeGit(ShellCommand(rawValue: "bash -c 'git reset --hard'")) == .unknown)
        #expect(analyzeFilesystem(ShellCommand(rawValue: "bash -c 'rm -rf Sources'")) == .unknown)
    }

    @Test func envChdir_changesFilesystemScope() {
        let context = FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo")
        )
        let analysis = analyzeSemantics(
            ShellCommand(rawValue: "env -C /tmp rm file"),
            filesystemContext: context
        )
        guard case .filesystem(.delete(let targets, _, _)) = analysis.innermost else {
            Issue.record("expected delete, got \(analysis)")
            return
        }
        #expect(targets[0].canonical == "/tmp/file")
        #expect(targets[0].scope == .outsideRepository)
        #expect(analysis.wrappers == [.env])
    }

    @Test func depthLimit_isUnwrapLimited() {
        let analysis = analyzeSemantics(
            ShellCommand(rawValue: "sudo env bash -c 'git reset --hard'"),
            maxDepth: 2
        )
        #expect(analysis.innermost == .unwrapLimited)
        #expect(analysis != .unknown)
    }
}
