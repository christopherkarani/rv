import RVDomain

/// Plain-sentence grammar first; the on-device model (then the fixture when
/// the model is unavailable) only for a sentence the grammar cannot read at
/// all (no verdict, or no command it knows), and only to find a rule.
/// A grammar refusal that names a word, an exception, or a second command is
/// final: asking a model there could save a rule wider than the sentence.
/// A model refusal never replaces the grammar's reason: on macOS 26 the
/// model answered `refuse(empty)` for every sentence, which is how
/// `rv policy draft` refused everything. Other errors propagate.
public struct EnglishCompileChain: ReasonedEnglishCompiler {
    private let phrases: PlainEnglishRuleCompiler?
    private let primary: any EnglishCompiler
    private let fallback: any EnglishCompiler

    /// The product chain: grammar, then Apple Foundation Models, then the fixture.
    public init() {
        self.phrases = PlainEnglishRuleCompiler()
        self.primary = FoundationModelsEnglishCompiler()
        self.fallback = FakeEnglishCompiler()
    }

    /// Model then fixture on `EnglishCompilerError.unavailable`; `phrases`
    /// (none by default) runs first when given.
    public init(
        primary: any EnglishCompiler,
        fallback: any EnglishCompiler = FakeEnglishCompiler(),
        phrases: PlainEnglishRuleCompiler? = nil
    ) {
        self.phrases = phrases
        self.primary = primary
        self.fallback = fallback
    }

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        try await compileWithReason(english).result
    }

    public func compileWithReason(_ english: String) async throws -> ReasonedCompileResult {
        guard let phrases else {
            return ReasonedCompileResult(result: try await model(english), reason: nil)
        }
        let draft = try await draft(english, phrases: phrases)
        return ReasonedCompileResult(result: PlainEnglishRuleCompiler.result(draft), reason: draft.reason)
    }

    private func draft(_ english: String, phrases: PlainEnglishRuleCompiler) async throws -> PlainEnglishRuleCompiler.Draft {
        let draft = phrases.draft(english)
        guard case .unreadable = draft else { return draft }
        // A model's rule must agree with the sentence's own words, then goes
        // through the grammar's checks and preview builder: never a
        // different rule than the sentence describes, never the input as
        // its title.
        if case .preview(let preview) = try await model(english) {
            return PlainEnglishRuleCompiler.reviewed(preview, english: english)
        }
        return draft
    }

    private func model(_ english: String) async throws -> EnglishCompileResult {
        do {
            return try await primary.compile(english)
        } catch EnglishCompilerError.unavailable {
            return try await fallback.compile(english)
        }
    }
}
