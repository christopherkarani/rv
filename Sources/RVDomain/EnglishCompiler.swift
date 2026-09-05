/// English → closed typed-rule preview, or refuse.
/// Foundation Models stay out of this module.
public protocol EnglishCompiler: Sendable {
    func compile(_ english: String) async throws -> EnglishCompileResult
}

/// Human preview of a typed rule. Draft is the matcher; English is not a field.
public struct RulePreview: Sendable, Equatable, Codable {
    public var sentence: String
    public var draft: TypedRule
    public var allowedToSave: Bool

    public init(sentence: String, draft: TypedRule, allowedToSave: Bool) {
        self.sentence = sentence
        self.draft = draft
        self.allowedToSave = allowedToSave
    }
}

public enum EnglishCompileResult: Sendable, Equatable, Codable {
    case preview(RulePreview)
    case refuse(EnglishCompileRefusal)
}

public enum EnglishCompileRefusal: String, Sendable, Equatable, Codable {
    case empty
    case uncompilable
    case unsupported
}

public enum EnglishCompilerError: Error, Sendable, Equatable {
    case unavailable
}

extension EnglishCompileResult {
    /// RVPolicy defines its own `RulePreview` (pin draft string), which shadows
    /// this module's preview type. Callers there must build a result without
    /// naming `RulePreview`.
    public static func makePreview(
        sentence: String,
        draft: TypedRule,
        allowedToSave: Bool
    ) -> EnglishCompileResult {
        .preview(RulePreview(sentence: sentence, draft: draft, allowedToSave: allowedToSave))
    }
}
