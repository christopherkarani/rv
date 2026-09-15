import Foundation
import Testing
import RVDomain
@testable import RVService

@Suite("GitLiveProbe")
struct GitLiveProbeTests {
    @Test func namedHEADMain_isSharedBranch() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/main\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.workingDirectory == cwd)
        #expect(facts.analysis.currentBranch == "main")
        #expect(facts.analysis.isSharedBranch)
        #expect(facts.rebaseInProgress == false)
    }

    @Test func namedHEADMaster_isSharedBranch() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/master\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == "master")
        #expect(facts.analysis.isSharedBranch)
    }

    @Test func namedHEADTopic_isNotShared() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/topic\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == "topic")
        #expect(facts.analysis.isSharedBranch == false)
    }

    @Test func nestedCwd_readsRepoHEAD() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/main\n")
        let nested = repo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let cwd = try #require(WorkingDirectory(validating: nested.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.workingDirectory == cwd)
        #expect(facts.analysis.currentBranch == "main")
        #expect(facts.analysis.isSharedBranch)
    }

    @Test func detachedSHA_isUnknownBranch() throws {
        let repo = try makeGitRepo(head: "0123456789abcdef0123456789abcdef01234567\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.workingDirectory == cwd)
        #expect(facts.analysis.currentBranch == nil)
        #expect(facts.analysis.isSharedBranch == false)
        #expect(facts.rebaseInProgress == false)
    }

    @Test func nilCwd_isUnknownBranch() {
        let facts = GitLiveProbe.facts(cwd: nil)
        #expect(facts.analysis.workingDirectory == nil)
        #expect(facts.analysis.currentBranch == nil)
        #expect(facts.analysis.isSharedBranch == false)
        #expect(facts.rebaseInProgress == false)
    }

    @Test func missingDirectory_isUnknownBranch() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-git-missing-\(UUID().uuidString)", isDirectory: true)
        let cwd = try #require(WorkingDirectory(validating: path.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.workingDirectory == cwd)
        #expect(facts.analysis.currentBranch == nil)
        #expect(facts.rebaseInProgress == false)
    }

    @Test func directoryWithoutGit_isUnknownBranch() throws {
        let root = try isolatedGitProbeRoot()
        let cwd = try #require(WorkingDirectory(validating: root.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.workingDirectory == cwd)
        #expect(facts.analysis.currentBranch == nil)
        #expect(facts.analysis.isSharedBranch == false)
        #expect(facts.rebaseInProgress == false)
    }

    @Test func missingHEAD_isUnknownBranch() throws {
        let repo = try makeGitRepo(head: nil)
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == nil)
        #expect(facts.rebaseInProgress == false)
    }

    @Test func nonHeadsRef_isUnknownBranch() throws {
        let repo = try makeGitRepo(head: "ref: refs/remotes/origin/main\n")
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == nil)
        #expect(facts.analysis.isSharedBranch == false)
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
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == "topic")
        #expect(facts.analysis.isSharedBranch == false)
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
        #expect(GitLiveProbe.facts(cwd: cwd).analysis.currentBranch == "topic")
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
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == "topic")
        #expect(facts.analysis.isSharedBranch == false)
    }

    @Test func rebaseMergeDir_isRebaseInProgress() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/topic\n")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git/rebase-merge", isDirectory: true),
            withIntermediateDirectories: true
        )
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == "topic")
        #expect(facts.rebaseInProgress)
        #expect(GitRebaseProbe.rebaseInProgress(cwd: cwd))
    }

    @Test func rebaseApplyDir_isRebaseInProgress() throws {
        let repo = try makeGitRepo(head: "ref: refs/heads/main\n")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git/rebase-apply", isDirectory: true),
            withIntermediateDirectories: true
        )
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let facts = GitLiveProbe.facts(cwd: cwd)
        #expect(facts.analysis.currentBranch == "main")
        #expect(facts.rebaseInProgress)
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
