import Foundation
import Testing
import RVDomain
@testable import RVPacks

let expectedGitSafe = [
    "checkout-new-branch", "checkout-orphan", "restore-staged-long",
    "restore-staged-short", "clean-dry-run-short", "clean-dry-run-long",
]
let expectedGitDestructive = [
    "git-alias-semantic-unverified", "branch-dynamic-token", "checkout-discard",
    "checkout-ref-discard", "restore-worktree", "restore-worktree-explicit",
    "reset-hard", "reset-merge", "clean-force", "push-force-long",
    "push-force-short", "branch-force-delete", "stash-drop", "stash-clear",
]
let expectedFilesystemSafe = [
    "rm-rf-tmp", "rm-fr-tmp", "rm-rf-var-tmp", "rm-fr-var-tmp", "rm-r-f-tmp",
    "rm-f-r-tmp", "rm-r-f-var-tmp", "rm-f-r-var-tmp", "rm-recursive-force-tmp",
    "rm-force-recursive-tmp", "rm-recursive-force-var-tmp", "rm-force-recursive-var-tmp",
    "find-delete-tmp", "find-delete-var-tmp", "unlink-tmp", "unlink-var-tmp",
    "unlink-help", "truncate-help", "truncate-grow", "truncate-tmp",
    "truncate-var-tmp", "shred-help", "shred-tmp", "shred-var-tmp",
    "tar-remove-files-tmp", "tar-remove-files-var-tmp", "dd-tmp", "dd-var-tmp",
    "dd-help", "mv-tmp", "mv-var-tmp", "mv-help", "mv-to-trash",
]
let expectedFilesystemDestructive = [
    "sed-exec-unverified", "cp-sensitive-then-delete",
    "ln-symlink-sensitive-then-delete", "rsync-sensitive-then-delete",
    "rm-rf-root-home", "rm-r-f-separate-root-home", "rm-recursive-force-root-home",
    "rm-rf-general", "rm-glob-home", "rm-r-f-separate", "rm-recursive-force-long",
    "find-delete-root-home", "find-delete-general", "unlink-root-home",
    "unlink-general", "truncate-zero-root-home", "truncate-zero-general",
    "shred-root-home", "shred-general", "tar-remove-files-root-home",
    "tar-remove-files-general", "dd-overwrite-root-home", "dd-overwrite-general",
    "mv-sensitive-source-root-home", "mv-dynamic-path",
    "redirect-truncate-root-home", "redirect-truncate-dynamic-path", "fork-bomb",
]

@Test func packLoad_decodesDayOneNameSets() throws {
    let packs = try PackRegistry.loadDayOne()
    #expect(packs.map(\.id.rawValue) == ["core.filesystem", "core.git"])
    let git = try #require(packs.first(where: { $0.id == .coreGit }))
    let filesystem = try #require(packs.first(where: { $0.id == .coreFilesystem }))
    #expect(git.safe.map(\.name) == expectedGitSafe)
    #expect(git.destructive.map(\.name) == expectedGitDestructive)
    #expect(filesystem.safe.map(\.name) == expectedFilesystemSafe)
    #expect(filesystem.destructive.map(\.name) == expectedFilesystemDestructive)
    #expect(git.destructive.contains { $0.name == "reset-hard" && $0.severity == .critical })
    #expect(git.destructive.contains { $0.name == "stash-drop" && $0.severity == .medium })
}

@Test func packLoad_coreStillDefaultOn() throws {
    let git = try PackRegistry.loadDocument(id: "core.git")
    let filesystem = try PackRegistry.loadDocument(id: "core.filesystem")
    #expect(git.enabledByDefault)
    #expect(filesystem.enabledByDefault)
    let disk = try PackRegistry.loadDocument(id: "system.disk")
    #expect(!disk.enabledByDefault)
}
