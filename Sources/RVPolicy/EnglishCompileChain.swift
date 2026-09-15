import RVDomain

/// AFM then Fake on `EnglishCompilerError.unavailable`. Other errors propagate.
public struct EnglishCompileChain: EnglishCompiler {
    private let primary: any EnglishCompiler
    private let fallback: any EnglishCompiler

    public init(
        primary: any EnglishCompiler = FoundationModelsEnglishCompiler(),
        fallback: any EnglishCompiler = FakeEnglishCompiler()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        do {
            return try await primary.compile(english)
        } catch EnglishCompilerError.unavailable {
            return try await fallback.compile(english)
        }
    }
}
