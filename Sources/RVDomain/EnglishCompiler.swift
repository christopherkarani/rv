/// English → closed typed-rule preview, or refuse.
/// Foundation Models stay out of this module.
public protocol EnglishCompiler: Sendable {
    func compile(_ english: String) async throws -> EnglishCompileResult
}

/// Human preview of a typed rule. Draft is the matcher; English is not a field.
/// Named apart from `RVPolicy.RulePreview`, whose draft is a pin string.
public struct TypedRulePreview: Sendable, Equatable, Codable {
    public let sentence: String
    public let draft: TypedRule
    public let allowedToSave: Bool

    public init(sentence: String, draft: TypedRule, allowedToSave: Bool) {
        self.sentence = sentence
        self.draft = draft
        self.allowedToSave = allowedToSave
    }
}

public enum EnglishCompileResult: Sendable, Equatable, Codable {
    case preview(TypedRulePreview)
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
