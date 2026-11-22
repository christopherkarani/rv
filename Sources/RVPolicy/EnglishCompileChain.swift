import RVDomain

/// Plain-sentence grammar first; the on-device model (then the fixture when
/// the model is unavailable) only for a sentence the grammar cannot read at
/// all (no verdict, or no command it knows), and only to find a rule.
/// A grammar refusal that names a word, an exception, or a second command is
/// final: asking a model there could save a rule wider than the sentence.
/// A model refusal never replaces the grammar's reason: on macOS 26 the
/// model answered `refuse(empty)` for every sentence, which is how
/// `rv policy draft` refused everything. Other errors propagate.
public struct EnglishCompileChain: EnglishCompiler {
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
        guard let phrases else {
            return try await model(english)
        }
        let draft = phrases.draft(english)
        guard case .unreadable = draft else {
            return PlainEnglishRuleCompiler.result(draft)
        }
        // A model's rule goes through the grammar's checks and preview
        // builder, so its title is the normalized sentence, never the input.
        if case .preview(let preview) = try await model(english) {
            return PlainEnglishRuleCompiler.result(PlainEnglishRuleCompiler.reviewed(preview, english: english))
        }
        return PlainEnglishRuleCompiler.result(draft)
    }

    private func model(_ english: String) async throws -> EnglishCompileResult {
        do {
            return try await primary.compile(english)
        } catch EnglishCompilerError.unavailable {
            return try await fallback.compile(english)
        }
    }
}
