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
        guard case .preview(let model) = try await chain.compile("under no circumstances force push to main") else {
            Issue.record("expected the model's rule")
            return
        }
        // The model's rule, under the grammar's own title.
        #expect(model.rule.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
        #expect(model.sentence == "Always block force-push to main")
        // Unsupported tools are the grammar's answer, not the model's.
        #expect(try await chain.compile("never npm publish") == .refuse(.unsupportedPredicate))
    }

    /// Review of #669: a sentence the grammar read and refused (a leftover
    /// word, an exception, two commands) never goes to the model, which
    /// could save a rule wider than the sentence.
    @Test(arguments: [
        "never force push to main on fridays", "never push except to feature", "never push unless it is main",
        "never push and reset", "never push tags",
    ])
    func productChain_finalGrammarRefusals_neverReachTheModel(sentence: String) async throws {
        let chain = EnglishCompileChain(
            primary: DistinctPreviewEnglishCompiler(sentence: "model-form"), fallback: FakeEnglishCompiler(),
            phrases: PlainEnglishRuleCompiler())
        guard case .refuse = try await chain.compile(sentence) else {
            Issue.record("expected the grammar's refusal for \(sentence)")
            return
        }
    }

    /// Mac test of #669: a model rule's title was the raw sentence. It now
    /// goes through the grammar's preview builder.
    @Test func productChain_modelRule_getsTheNormalizedTitle() async throws {
        let english = "pushing with force to main is fine"
        let chain = EnglishCompileChain(
            primary: FormEnglishCompiler(force: .exactly(.force), branch: "main", verdict: .allow),
            fallback: FakeEnglishCompiler(), phrases: PlainEnglishRuleCompiler())
        guard case .preview(let preview) = try await chain.compile(english) else {
            Issue.record("expected the model's rule")
            return
        }
        #expect(preview.sentence == "Always allow force-push to main")
        #expect(preview.sentence != english)
        #expect(preview.rule.english == english)
    }

    /// A model's branch passes the grammar's branch checks: no look-alike
    /// letters, no nouns, no patterns.
    @Test(arguments: ["m\u{0430}in", "tags", "release/*"])
    func productChain_modelBranch_isChecked(branch: String) async throws {
        let chain = EnglishCompileChain(
            primary: FormEnglishCompiler(force: .exactly(.force), branch: branch, verdict: .deny),
            fallback: FakeEnglishCompiler(), phrases: PlainEnglishRuleCompiler())
        guard case .refuse = try await chain.compile("under no circumstances force push to \(branch)") else {
            Issue.record("expected a refusal for branch \(branch)")
            return
        }
    }

    /// Mac recheck of #669: the model sometimes returned force=none for a
    /// force-push sentence. A model rule must agree with the sentence's own
    /// words (verdict, push, force kind, branch) or it is refused.
    @Test(arguments: [
        // force sentence, model says no force
        ("under no circumstances force push to main", GitPushForceConstraint.exactly(.none), "main" as String?,
         TypedRuleVerdict.deny, "it says force-push"),
        // no force in the sentence, model says force
        ("under no circumstances push to main", .exactly(.force), "main", .deny, "and the draft was force-push"),
        // force-with-lease sentence, model says plain force
        ("under no circumstances push --force-with-lease to main", .exactly(.force), "main", .deny,
         "it says --force-with-lease"),
        // branch the sentence never names
        ("under no circumstances force push to main", .exactly(.force), "release", .deny,
         "doesn't name the branch release"),
        // every branch, when the sentence names one
        ("under no circumstances force push to main", .exactly(.force), nil, .deny, "covers every branch"),
        // verdict flipped
        ("under no circumstances force push to main", .exactly(.force), "main", .allow, "reads as deny"),
        ("pushing with force to main is fine", .exactly(.force), "main", .deny, "reads as allow"),
        // no push in the sentence
        ("keep main safe from forced history rewrites", .exactly(.force), "main", .deny, "doesn't say push"),
    ])
    func productChain_modelRuleThatDisagrees_isRefused(
        english: String, force: GitPushForceConstraint, branch: String?, verdict: TypedRuleVerdict, why: String
    ) async throws {
        let chain = EnglishCompileChain(
            primary: FormEnglishCompiler(force: force, branch: branch, verdict: verdict),
            fallback: FakeEnglishCompiler(), phrases: PlainEnglishRuleCompiler())
        let answer = try await chain.compileWithReason(english)
        #expect(answer.result == .refuse(.uncompilable), "\(english)")
        #expect(answer.reason?.contains(why) == true, "\(english): \(answer.reason ?? "nil")")
        #expect(answer.reason?.hasPrefix("can't read this sentence for sure: ") == true)
    }

    @Test func productChain_modelRuleThatAgrees_isKept() async throws {
        let chain = EnglishCompileChain(
            primary: FormEnglishCompiler(force: .exactly(.forceWithLease), branch: "main", verdict: .ask),
            fallback: FakeEnglishCompiler(), phrases: PlainEnglishRuleCompiler())
        let answer = try await chain.compileWithReason("check with the team first when pushing --force-with-lease to main")
        guard case .preview(let preview) = answer.result else {
            Issue.record("expected the model's rule, got \(answer)")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .exactly(.forceWithLease), branch: "main"))
        #expect(answer.reason == nil)
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

/// A model that fills the git push form and titles it with the raw input.
private struct FormEnglishCompiler: EnglishCompiler {
    var force: GitPushForceConstraint
    var branch: String?
    var verdict: TypedRuleVerdict

    func compile(_ english: String) async throws -> EnglishCompileResult {
        FoundationModelsEnglishCompileMapping.preview(
            force: force, branch: branch, verdict: verdict, sentence: english, english: english)
    }
}

private struct EmptyRefusingEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        .refuse(.empty)
    }
}
