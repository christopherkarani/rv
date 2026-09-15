import Testing
import RVDomain
@testable import RVPolicy

struct EnglishCompileChainTests {
    @Test func productInit_isEnglishCompiler() {
        let chain = EnglishCompileChain()
        let _: any EnglishCompiler = chain
    }

    @Test func unavailablePrimary_fixtureEnglish_previewsCannedGitPushDeny() async throws {
        let chain = EnglishCompileChain(
            primary: UnavailableEnglishCompiler(),
            fallback: FakeEnglishCompiler()
        )
        let result = try await chain.compile("never allow force-push to main")
        guard case .preview(let preview) = result else {
            Issue.record("expected preview, got \(result)")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.rule.verdict == .deny)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence == "Always block force-push to main")
        #expect(preview.rule.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
    }

    @Test func unavailablePrimary_uncompilableEnglish_refuses() async throws {
        let chain = EnglishCompileChain(
            primary: UnavailableEnglishCompiler(),
            fallback: FakeEnglishCompiler()
        )
        let result = try await chain.compile("be careful in prod")
        #expect(result == .refuse(.uncompilable))
    }

    @Test func disabledSystemModel_fallsBackToFakeWithoutLiveApple() async throws {
        let chain = EnglishCompileChain(
            primary: FoundationModelsEnglishCompiler(usesSystemModel: false),
            fallback: FakeEnglishCompiler()
        )
        let result = try await chain.compile("never allow force-push to main")
        guard case .preview(let preview) = result else {
            Issue.record("expected preview from Fake fallback, got \(result)")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.allowedToSave == true)
    }

    @Test func primaryPreview_doesNotCallFallback() async throws {
        let chain = EnglishCompileChain(
            primary: DistinctPreviewEnglishCompiler(sentence: "primary-form"),
            fallback: DistinctPreviewEnglishCompiler(sentence: "fallback-form")
        )
        let result = try await chain.compile("never allow force-push to main")
        guard case .preview(let preview) = result else {
            Issue.record("expected primary preview, got \(result)")
            return
        }
        #expect(preview.sentence == "primary-form")
    }

    @Test func cancellation_propagatesWithoutFallback() async {
        let chain = EnglishCompileChain(
            primary: CancelledEnglishCompiler(),
            fallback: DistinctPreviewEnglishCompiler(sentence: "fallback-form")
        )
        await #expect(throws: CancellationError.self) {
            _ = try await chain.compile("never allow force-push to main")
        }
    }

    @Test func otherError_propagatesWithoutFallback() async {
        let chain = EnglishCompileChain(
            primary: ExplodingEnglishCompiler(),
            fallback: DistinctPreviewEnglishCompiler(sentence: "fallback-form")
        )
        await #expect(throws: Boom.self) {
            _ = try await chain.compile("never allow force-push to main")
        }
    }
}

private struct UnavailableEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        throw EnglishCompilerError.unavailable
    }
}

private struct CancelledEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        throw CancellationError()
    }
}

private struct Boom: Error {}

private struct ExplodingEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        throw Boom()
    }
}

private struct DistinctPreviewEnglishCompiler: EnglishCompiler {
    var sentence: String

    func compile(_ english: String) async throws -> EnglishCompileResult {
        .preview(
            TypedRulePreview(
                sentence: sentence,
                rule: PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                    verdict: .deny,
                    predicate: .gitPush(force: .force, branch: "main"),
                    english: english
                ),
                allowedToSave: true
            )
        )
    }
}
