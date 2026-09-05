import Testing
import RVDomain

@Suite("FakeEnglishCompilerTests")
struct FakeEnglishCompilerTests {
    @Test(arguments: [
        "never force-push main",
        "never allow force-push to main",
    ])
    func compile_knownDenySentence_yieldsGitPushForceMainDeny(_ english: String) async throws {
        let compiler = FakeEnglishCompiler()
        let result = try await compiler.compile(english)
        guard case .preview(let preview) = result else {
            Issue.record("expected preview, got \(result)")
            return
        }
        #expect(preview.draft.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.draft.verdict == .deny)
        #expect(preview.draft.origin == .machine)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence == "Always block force-push to main.")
        #expect(preview.draft.id == RuleID(pack: .coreGit, pattern: "force-push-main"))
    }

    @Test(arguments: [
        "be careful in prod",
        "please be nice",
    ])
    func compile_unknownSentence_refusesUncompilable(_ english: String) async throws {
        let result = try await FakeEnglishCompiler().compile(english)
        #expect(result == .refuse(.uncompilable))
    }

    @Test func compile_isUsableAsEnglishCompilerExistential() async throws {
        let compiler: any EnglishCompiler = FakeEnglishCompiler()
        let result = try await compiler.compile("never allow force-push to main")
        guard case .preview(let preview) = result else {
            Issue.record("expected preview through any EnglishCompiler")
            return
        }
        #expect(preview.draft.predicate == .gitPush(force: .force, branch: "main"))
    }
}
