import RVDomain

/// Plain-sentence grammar first; the on-device model (then the fixture when
/// the model is unavailable) only for a sentence the grammar cannot read,
/// and only to find a rule. A model refusal never replaces the grammar's
/// reason: on macOS 26 the model answered `refuse(empty)` for every
/// sentence, which is how `rv policy draft` refused everything.
/// Other errors propagate.
public struct EnglishCompileChain: EnglishCompiler {
    private let phrases: (any EnglishCompiler)?
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
        phrases: (any EnglishCompiler)? = nil
    ) {
        self.phrases = phrases
        self.primary = primary
        self.fallback = fallback
    }

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        guard let phrases else {
            return try await model(english)
        }
        let grammar = try await phrases.compile(english)
        guard case .refuse(.uncompilable) = grammar else {
            return grammar
        }
        let modelResult = try await model(english)
        if case .preview = modelResult {
            return modelResult
        }
        return grammar
    }

    private func model(_ english: String) async throws -> EnglishCompileResult {
        do {
            return try await primary.compile(english)
        } catch EnglishCompilerError.unavailable {
            return try await fallback.compile(english)
        }
    }
}
