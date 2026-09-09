import Testing
import RVDomain

struct FakeEnglishCompilerTests {
    @Test(arguments: [
        "never force-push main",
        "never allow force-push to main",
    ])
    func compile_knownDenySentence_yieldsGitPushForceMainDeny(_ english: String) async throws {
        let result = try await FakeEnglishCompiler().compile(english)
        guard case .preview(let preview) = result else {
            Issue.record("expected preview, got \(result)")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.rule.verdict == .deny)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence == "Always block force-push to main")
        #expect(preview.rule.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
        #expect(preview.rule.english == english)
        let typed = preview.rule.typedRule(origin: .machine)
        #expect(typed.predicate == preview.rule.predicate)
    }

    @Test(arguments: [
        "be careful in prod",
        "please be nice",
    ])
    func compile_unknownSentence_refusesUncompilable(_ english: String) async throws {
        let result = try await FakeEnglishCompiler().compile(english)
        #expect(result == .refuse(.uncompilable))
    }

    @Test func compile_empty_refusesEmpty() async throws {
        let result = try await FakeEnglishCompiler().compile("  ")
        #expect(result == .refuse(.empty))
    }

    @Test func compile_isUsableAsEnglishCompilerExistential() async throws {
        let compiler: any EnglishCompiler = FakeEnglishCompiler()
        let result = try await compiler.compile("never allow force-push to main")
        guard case .preview(let preview) = result else {
            Issue.record("expected preview through any EnglishCompiler")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .force, branch: "main"))
    }
}
