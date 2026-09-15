import Foundation
import Testing
import RVDomain
@testable import RVService

@Suite("GitLiveProbe")
struct GitLiveProbeTests {
    @Test(arguments: ["main", "master", "feature/foo"])
    func namedHEAD_fillsCurrentBranch(_ name: String) throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/\(name)\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let context = GitLiveProbe.context(cwd: cwd)
        #expect(context.workingDirectory == cwd)
        #expect(context.currentBranch == name)
        #expect(context.isSharedBranch == false)
    }

    @Test func nestedCwd_readsRepoHEAD() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/main\n")
        let nested = repo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let cwd = try #require(WorkingDirectory(validating: nested.path))
        let context = GitLiveProbe.context(cwd: cwd)
        #expect(context.workingDirectory == cwd)
        #expect(context.currentBranch == "main")
    }

    @Test func detachedSHA_isUnknownBranch() throws {
        let repo = try makeGitRepo(head: "0123456789abcdef0123456789abcdef01234567\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let context = GitLiveProbe.context(cwd: cwd)
        #expect(context.workingDirectory == cwd)
        #expect(context.currentBranch == nil)
    }

    @Test func nilCwd_isUnknownBranch() {
        let context = GitLiveProbe.context(cwd: nil)
        #expect(context.workingDirectory == nil)
        #expect(context.currentBranch == nil)
    }

    @Test func missingDirectory_isUnknownBranch() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-git-missing-\(UUID().uuidString)", isDirectory: true)
        let cwd = try #require(WorkingDirectory(validating: path.path))
        let context = GitLiveProbe.context(cwd: cwd)
        #expect(context.workingDirectory == cwd)
        #expect(context.currentBranch == nil)
    }

    @Test func directoryWithoutGit_isUnknownBranch() throws {
        let root = try isolatedGitProbeRoot()
        let cwd = try #require(WorkingDirectory(validating: root.path))
        let context = GitLiveProbe.context(cwd: cwd)
        #expect(context.workingDirectory == cwd)
        #expect(context.currentBranch == nil)
    }

    @Test func missingHEAD_isUnknownBranch() throws {
        let repo = try makeGitRepo(head: nil)
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        #expect(GitLiveProbe.context(cwd: cwd).currentBranch == nil)
    }

    @Test func nonHeadsRef_isUnknownBranch() throws {
        let repo = try makeGitRepo(head: "ref: refs/remotes/origin/main\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        #expect(GitLiveProbe.context(cwd: cwd).currentBranch == nil)
    }

    @Test func worktreeGitdirFile_usesCheckoutHEAD() throws {
        let root = try isolatedGitProbeRoot()
        let main = root.appendingPathComponent("main", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let wtGitdir = main.appendingPathComponent(".git/worktrees/wt", isDirectory: true)
        try FileManager.default.createDirectory(at: wtGitdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: main.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/topic\n".write(
            to: wtGitdir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(wtGitdir.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let cwd = try #require(WorkingDirectory(validating: worktree.path))
        let context = GitLiveProbe.context(cwd: cwd)
        #expect(context.currentBranch == "topic")
    }

    @Test func relativeGitdirFile_usesCheckoutHEAD() throws {
        let root = try isolatedGitProbeRoot()
        let gitdir = root.appendingPathComponent("gitdir", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "ref: refs/heads/topic\n".write(
            to: gitdir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: ../gitdir\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let cwd = try #require(WorkingDirectory(validating: worktree.path))
        #expect(GitLiveProbe.context(cwd: cwd).currentBranch == "topic")
    }

    @Test func remotesAreNotScraped() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/topic\n")
        let origin = repo.appendingPathComponent(".git/refs/remotes/origin", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: origin.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "[branch \"topic\"]\n\tremote = origin\n\tmerge = refs/heads/main\n".write(
            to: repo.appendingPathComponent(".git/config"),
            atomically: true,
            encoding: .utf8
        )
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let context = GitLiveProbe.context(cwd: cwd)
        #expect(context.currentBranch == "topic")
        #expect(context.isSharedBranch == false)
    }
}

private func makeGitRepo(head: String?) throws -> URL {
    let root = try isolatedGitProbeRoot()
    let git = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    if let head {
        try head.write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    }
    return root
}

private func isolatedGitProbeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-git-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
