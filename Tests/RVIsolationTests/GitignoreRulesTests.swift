import Testing
@testable import RVIsolation

@Suite("Gitignore rules")
struct GitignoreRulesTests {
    private func ignored(_ text: String, _ path: String, directory: Bool = false, base: [String] = []) -> Bool {
        GitignoreRules().adding(text, base: base)
            .isIgnored(path.split(separator: "/").map(String.init), isDirectory: directory)
    }

    @Test func aPatternWithoutSlashMatchesTheNameAtAnyDepth() {
        #expect(ignored("*.log\n", "build.log"))
        #expect(ignored("*.log\n", "a/b/build.log"))
        #expect(ignored("*.log\n", "a/b/build.txt") == false)
        #expect(ignored("node_modules\n", "pkg/node_modules", directory: true))
    }

    @Test func commentsBlankLinesAndEscapes() {
        #expect(ignored("# comment\n\n", "# comment") == false)
        #expect(ignored("\\#notes\n", "#notes"))
        #expect(ignored("\\!bang\n", "!bang"))
        #expect(ignored("trailing   \n", "trailing"))
        #expect(ignored("space\\ \n", "space "))
    }

    @Test func aLeadingOrInnerSlashAnchorsToTheBase() {
        #expect(ignored("/dist\n", "dist", directory: true))
        #expect(ignored("/dist\n", "app/dist", directory: true) == false)
        #expect(ignored("docs/*.md\n", "docs/a.md"))
        #expect(ignored("docs/*.md\n", "x/docs/a.md") == false)
        #expect(ignored("docs/*.md\n", "docs/sub/a.md") == false)
    }

    @Test func aTrailingSlashMatchesDirectoriesOnly() {
        #expect(ignored("out/\n", "out", directory: true))
        #expect(ignored("out/\n", "out") == false)
    }

    @Test func doubleStarMatchesAnyNumberOfDirectories() {
        #expect(ignored("**/cache\n", "cache", directory: true))
        #expect(ignored("**/cache\n", "a/b/cache", directory: true))
        #expect(ignored("logs/**\n", "logs/a/b.txt"))
        #expect(ignored("a/**/z\n", "a/z"))
        #expect(ignored("a/**/z\n", "a/b/c/z"))
        #expect(ignored("a/**/z\n", "b/a/z") == false)
    }

    @Test func questionMarkAndBracketClasses() {
        #expect(ignored("file?.txt\n", "file1.txt"))
        #expect(ignored("file?.txt\n", "file10.txt") == false)
        #expect(ignored("[abc].c\n", "b.c"))
        #expect(ignored("[!abc].c\n", "b.c") == false)
        #expect(ignored("[!abc].c\n", "d.c"))
        #expect(ignored("[a-c]x\n", "bx"))
        #expect(ignored("[a-c]x\n", "dx") == false)
    }

    @Test func theLastMatchingRuleWinsAndNegationReincludes() {
        #expect(ignored("*.env\n!example.env\n", "example.env") == false)
        #expect(ignored("*.env\n!example.env\n", "prod.env"))
        #expect(ignored("!keep.txt\n*.txt\n", "keep.txt"))
    }

    @Test func nestedRulesApplyOnlyUnderTheirDirectory() {
        let rules = GitignoreRules()
            .adding("*.tmp\n", base: [])
            .adding("secret.txt\n!b.tmp\n", base: ["sub"])
        #expect(rules.isIgnored(["secret.txt"], isDirectory: false) == false)
        #expect(rules.isIgnored(["sub", "secret.txt"], isDirectory: false))
        #expect(rules.isIgnored(["sub", "deeper", "secret.txt"], isDirectory: false))
        #expect(rules.isIgnored(["a.tmp"], isDirectory: false))
        #expect(rules.isIgnored(["sub", "b.tmp"], isDirectory: false) == false)
        #expect(rules.isIgnored(["other", "b.tmp"], isDirectory: false))
    }

    @Test func anchoredNestedRuleIsRelativeToItsDirectory() {
        let rules = GitignoreRules().adding("/only-here\n", base: ["pkg"])
        #expect(rules.isIgnored(["pkg", "only-here"], isDirectory: false))
        #expect(rules.isIgnored(["pkg", "x", "only-here"], isDirectory: false) == false)
        #expect(rules.isIgnored(["only-here"], isDirectory: false) == false)
    }

    @Test func pathologicalStarsStayBounded() {
        let pattern = String(repeating: "*a", count: 40) + "b\n"
        let name = String(repeating: "a", count: 200)
        #expect(ignored(pattern, name) == false)
    }
}
