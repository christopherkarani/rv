import Foundation
import Testing
import RVDomain
import RVEngine
@testable import RVService

@Suite("GitLiveProbe")
struct GitLiveProbeTests {
    @Test(arguments: ["main", "master"])
    func attachedSharedBranch_isProbedShared(name: String) throws {
        let repo = try makeGitRepo(head: .attached(name))
        defer { try? FileManager.default.removeItem(at: repo) }
        let context = try requireProbed(fallback: wd(repo.path))
        #expect(context.currentBranch == name)
        #expect(context.isSharedBranch == true)
        #expect(context.workingDirectory == wd(repo.path))
    }

    @Test func attachedFeature_isProbedNotShared() throws {
        let repo = try makeGitRepo(head: .attached("feature"))
        defer { try? FileManager.default.removeItem(at: repo) }
        let context = try requireProbed(fallback: wd(repo.path))
        #expect(context.currentBranch == "feature")
        #expect(context.isSharedBranch == false)
    }

    @Test func detachedHEAD_isProbedUnknown() throws {
        let repo = try makeGitRepo(head: .detached)
        defer { try? FileManager.default.removeItem(at: repo) }
        let context = try requireProbed(fallback: wd(repo.path))
        #expect(context.currentBranch == nil)
        #expect(context.isSharedBranch == false)
        #expect(context.workingDirectory == wd(repo.path))
    }

    @Test func missingHEAD_isProbedUnknown() throws {
        let repo = try makeGitRepo(head: .missing)
        defer { try? FileManager.default.removeItem(at: repo) }
        let context = try requireProbed(fallback: wd(repo.path))
        #expect(context.currentBranch == nil)
        #expect(context.isSharedBranch == false)
    }

    @Test func missingRepo_isProbedUnknownNotUnprobed() throws {
        let root = try makeEmptyWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let world = GitLiveProbe.world(
            unwrapped: complete(cwd: wd(root.path)),
            fallbackCwd: wd(root.path)
        )
        #expect(world != .unprobed)
        let context = try #require(probedContext(world))
        #expect(context.currentBranch == nil)
        #expect(context.isSharedBranch == false)
        #expect(context.workingDirectory == wd(root.path))
    }

    @Test func missingCwd_isProbedUnknown() throws {
        let world = GitLiveProbe.world(
            unwrapped: complete(cwd: nil),
            fallbackCwd: nil
        )
        #expect(world != .unprobed)
        let context = try #require(probedContext(world))
        #expect(context.currentBranch == nil)
        #expect(context.isSharedBranch == false)
        #expect(context.workingDirectory == nil)
    }

    @Test func unwrappedCwd_beatsFallback() throws {
        let main = try makeGitRepo(head: .attached("main"))
        let feature = try makeGitRepo(head: .attached("feature"))
        defer {
            try? FileManager.default.removeItem(at: main)
            try? FileManager.default.removeItem(at: feature)
        }
        let context = try requireProbed(
            unwrapped: complete(cwd: wd(main.path)),
            fallback: wd(feature.path)
        )
        #expect(context.currentBranch == "main")
        #expect(context.isSharedBranch == true)
        #expect(context.workingDirectory == wd(main.path))
    }

    @Test func limitedUnwrap_usesFallbackCwd() throws {
        let repo = try makeGitRepo(head: .attached("main"))
        defer { try? FileManager.default.removeItem(at: repo) }
        let context = try requireProbed(
            unwrapped: .limited(layers: []),
            fallback: wd(repo.path)
        )
        #expect(context.currentBranch == "main")
        #expect(context.isSharedBranch == true)
    }

    @Test func gitdirFile_readsHEADFromResolvedGitDir() throws {
        let root = try makeEmptyWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitdir = root.appendingPathComponent("gitdir", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: gitdir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: ../gitdir\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let context = try requireProbed(fallback: wd(worktree.path))
        #expect(context.currentBranch == "main")
        #expect(context.isSharedBranch == true)
    }

    @Test func sharedGitdirHelper_servesHEADAndRebaseMarker() throws {
        let root = try makeEmptyWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitdir = root.appendingPathComponent("gitdir", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitdir.appendingPathComponent("rebase-merge", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "ref: refs/heads/feature\n".write(
            to: gitdir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(gitdir.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let resolved = try #require(GitLiveProbe.resolvedGitDir(repoRoot: worktree.path))
        #expect(FileManager.default.fileExists(atPath: resolved + "/HEAD"))
        #expect(FileManager.default.fileExists(atPath: resolved + "/rebase-merge"))
        #expect(GitRebaseProbe.rebaseInProgress(cwd: wd(worktree.path)))
        let context = try requireProbed(fallback: wd(worktree.path))
        #expect(context.currentBranch == "feature")
        #expect(context.isSharedBranch == false)
    }
}

private enum GitHEAD {
    case attached(String)
    case detached
    case missing
}

private func requireProbed(
    unwrapped: UnwrapOutcome? = nil,
    fallback: WorkingDirectory?,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> GitAnalysisContext {
    let outcome = unwrapped ?? complete(cwd: fallback)
    let world = GitLiveProbe.world(unwrapped: outcome, fallbackCwd: fallback)
    #expect(world != .unprobed, sourceLocation: sourceLocation)
    return try #require(probedContext(world), sourceLocation: sourceLocation)
}

private func probedContext(_ world: GitAnalysisWorld) -> GitAnalysisContext? {
    if case .probed(let context) = world {
        return context
    }
    return nil
}

private func complete(cwd: WorkingDirectory?) -> UnwrapOutcome {
    .complete(
        UnwrappedCommand(
            command: ShellCommand(rawValue: "git push --force-with-lease"),
            workingDirectory: cwd
        )
    )
}

private func makeEmptyWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-git-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeGitRepo(head: GitHEAD) throws -> URL {
    let root = try makeEmptyWorkspace()
    let git = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    switch head {
    case .attached(let name):
        try "ref: refs/heads/\(name)\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    case .detached:
        try "0123456789abcdef0123456789abcdef01234567\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    case .missing:
        break
    }
    return root
}
