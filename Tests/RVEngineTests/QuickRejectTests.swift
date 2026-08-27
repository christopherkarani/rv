import Foundation
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

@Test func quickReject_asciiKeywordsPreserveCaseAndWordBoundaries() {
    #expect(QuickReject.keywordHits("git", in: "GIT status"))
    #expect(QuickReject.keywordHits("git", in: "git/status"))
    #expect(QuickReject.keywordHits("git", in: "égit"))
    #expect(QuickReject.keywordHits("git", in: "gité"))
    #expect(!QuickReject.keywordHits("git", in: "digit status"))
    #expect(!QuickReject.keywordHits("git", in: "gitignore"))
    #expect(!QuickReject.keywordHits("git", in: "git-branch"))
    #expect(!QuickReject.keywordHits("git", in: "git_branch"))
}

@Test func quickReject_emptyKeywordAndParenWhitespaceKeepExistingSemantics() {
    #expect(!QuickReject.keywordHits("", in: "git status"))
    #expect(QuickReject.keywordHits("café", in: "café"))
    #expect(!QuickReject.keywordHits("café", in: "CAFÉ"))
    #expect(QuickReject.containsEmptyParenPair("🧪 ( \t\n\r )"))
    #expect(QuickReject.containsEmptyParenPair("()"))
    #expect(!QuickReject.containsEmptyParenPair("🧪 (\u{00A0})"))
    #expect(!QuickReject.containsEmptyParenPair("( \n ]"))
}

@Test func quickReject_interiorNULKeepsUTF8ScanWithinBounds() {
    #expect(QuickReject.keywordHits("git", in: "git\u{0000} status"))
    #expect(QuickReject.keywordHits("git", in: "\u{0000}git"))
    #expect(!QuickReject.keywordHits("git", in: "dig\u{0000}it"))
}

@Test func quickReject_handlesBridgedStringStorage() {
    let foreign = NSMutableString(string: "git ( )")
    let haystack = foreign as String

    // Foundation may normalize the bridge to contiguous native storage.
    #expect(QuickReject.keywordHits("git", in: haystack))
    #expect(QuickReject.containsEmptyParenPair(haystack))

    let foreignBoundary = NSMutableString(string: "digit ( )")
    let boundaryMiss = foreignBoundary as String
    #expect(!QuickReject.keywordHits("git", in: boundaryMiss))
    #expect(QuickReject.containsEmptyParenPair(boundaryMiss))
}
