import Testing
import RVDomain
@testable import RVEngine

private let gitPack = PackSnapshot(
    id: .coreGit,
    name: "Core Git",
    description: "test",
    keywords: ["git"],
    safe: [],
    destructive: []
)

private let filesystemPack = PackSnapshot(
    id: .coreFilesystem,
    name: "Core Filesystem",
    description: "test",
    keywords: ["rm", ">/", "> /"],
    safe: [],
    destructive: []
)

@Test func quickReject_skipsUnrelatedCommands() {
    let enabled = [gitPack, filesystemPack]
    #expect(QuickReject.shouldSkip(matchingView: "ls -la", enabled: enabled))
    #expect(QuickReject.shouldSkip(matchingView: "echo hello", enabled: enabled))
    #expect(QuickReject.shouldSkip(matchingView: "echo digit", enabled: enabled))
    #expect(QuickReject.shouldSkip(matchingView: "cat .gitignore", enabled: enabled))
}

@Test func quickReject_keepsGitAndRm() {
    let enabled = [gitPack, filesystemPack]
    #expect(!QuickReject.shouldSkip(matchingView: "git status", enabled: enabled))
    #expect(!QuickReject.shouldSkip(matchingView: "rm -rf ./src", enabled: enabled))
    #expect(!QuickReject.shouldSkip(matchingView: "echo $(git reset --hard)", enabled: enabled))
    #expect(!QuickReject.shouldSkip(matchingView: "echo `git reset --hard`", enabled: enabled))
}

@Test func quickReject_forceScansEmptyParen() {
    let enabled = [gitPack, filesystemPack]
    #expect(!QuickReject.shouldSkip(matchingView: ":(){ :|:& };:", enabled: enabled))
    #expect(QuickReject.containsEmptyParenPair("foo ( ) { bar; }"))
}
