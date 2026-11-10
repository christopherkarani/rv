import Testing
import RVDomain
@testable import RVEngine

/// `.git` is git's own state: hooks and config run code and
/// `.git/rebase-merge` is the whole proof behind the rebase-recovery
/// override. In-repo-write policy allowed an agent to mutate it directly.
@Suite("Git internals protection")
struct GitInternalsProtectionTests {
    private let repo = FilesystemAnalysisWorld.probed(
        FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo")
        )
    )

    @Test(
        "agent mutation of .git internals is a protected-path deny",
        arguments: [
            "rm -r .git",
            "rm -r ./.git/",
            "echo x > .git/hooks/pre-commit",
            "cp hook.sh .git/hooks/pre-commit",
            "mkdir -p .git/rebase-merge",
            "mkdir .git/rebase-apply",
            "touch .git/rebase-merge/head-name",
            "echo '[alias] z = reset --hard' >> .git/config",
            "mv /repo/notes .git/config",
            "rm -r .GIT",
            "rm -r vendor/lib/.git",
            "cd src && rm -r ../.git",
        ]
    )
    func mutationDenies(_ command: String) throws {
        let result = try runSemanticsDoor(command, filesystemProbe: { _ in repo })
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(command) must deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID, "\(command)")
    }

    @Test(
        "reads of .git and look-alike names stay allowed",
        arguments: [
            "cat .git/HEAD",
            "ls .git",
            "echo build >> .gitignore",
            "mkdir -p .github/workflows",
            "touch src/a.txt",
            "rm -r build",
        ]
    )
    func readsAndLookAlikesAllow(_ command: String) throws {
        let result = try runSemanticsDoor(command, filesystemProbe: { _ in repo })
        #expect(result.decision == .allow, "\(command): \(result.decision)")
    }

    @Test func gitInternalPath_matchesComponentOnly() {
        #expect(isGitInternalPath("/repo/.git"))
        #expect(isGitInternalPath("/repo/.git/hooks/pre-commit"))
        #expect(isGitInternalPath("/repo/.Git/config"))
        #expect(isGitInternalPath("/repo/.gitignore") == false)
        #expect(isGitInternalPath("/repo/.github/x") == false)
        #expect(isGitInternalPath("/repo/proj.git/x") == false)
    }
}
