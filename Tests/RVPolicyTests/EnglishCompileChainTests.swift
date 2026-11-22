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
        #expect(preview.rule.predicate == .gitPush(force: .exactly(.force), branch: "main"))
        #expect(preview.rule.verdict == .deny)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence == "Always block force-push to main")
        #expect(preview.rule.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
        #expect(preview.rule.english == "never allow force-push to main")
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
        #expect(preview.rule.predicate == .gitPush(force: .exactly(.force), branch: "main"))
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

    /// The bug on macOS 26: the on-device model answered `refuse(empty)` for
    /// every sentence. The grammar now drafts first, so a plain sentence
    /// never reaches the model.
    @Test func productChain_draftsPlainSentencesEvenWhenTheModelRefusesEmpty() async throws {
        let chain = EnglishCompileChain(
            primary: EmptyRefusingEnglishCompiler(), fallback: FakeEnglishCompiler(),
            phrases: PlainEnglishRuleCompiler())
        for sentence in ["never force push to main", "never allow force-push to main", "block git reset --hard"] {
            guard case .preview = try await chain.compile(sentence) else {
                Issue.record("expected a rule for \(sentence)")
                continue
            }
        }
        #expect(try await chain.compile("never delete files outside this repo") == .refuse(.alreadyBuiltIn))
        // The grammar's refusal stands over the model's "empty".
        #expect(try await chain.compile("be careful in prod") == .refuse(.uncompilable))
    }

    @Test func productChain_asksTheModelOnlyForWhatTheGrammarCannotRead() async throws {
        let chain = EnglishCompileChain(
            primary: DistinctPreviewEnglishCompiler(sentence: "model-form"), fallback: FakeEnglishCompiler(),
            phrases: PlainEnglishRuleCompiler())
        guard case .preview(let grammar) = try await chain.compile("never force push to main") else {
            Issue.record("expected the grammar's rule")
            return
        }
        #expect(grammar.sentence == "Always block force-push to main")
        guard case .preview(let model) = try await chain.compile("keep main safe from forced history rewrites") else {
            Issue.record("expected the model's rule")
            return
        }
        #expect(model.sentence == "model-form")
        // Unsupported tools are the grammar's answer, not the model's.
        #expect(try await chain.compile("never npm publish") == .refuse(.unsupportedPredicate))
    }

    @Test func productChain_modelUnavailable_keepsTheGrammarReason() async throws {
        let chain = EnglishCompileChain(
            primary: UnavailableEnglishCompiler(), fallback: FakeEnglishCompiler(),
            phrases: PlainEnglishRuleCompiler())
        #expect(try await chain.compile("be careful in prod") == .refuse(.uncompilable))
        guard case .preview = try await chain.compile("ask before pushing to release") else {
            Issue.record("expected a rule")
            return
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
                    predicate: .gitPush(force: .exactly(.force), branch: "main"),
                    english: english
                ),
                allowedToSave: true
            )
        )
    }
}

private struct EmptyRefusingEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        .refuse(.empty)
    }
}
