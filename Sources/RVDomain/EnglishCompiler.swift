/// English → closed typed-rule preview, or refuse.
/// Foundation Models stay out of this module.
public protocol EnglishCompiler: Sendable {
    func compile(_ english: String) async throws -> EnglishCompileResult
}

/// Human preview of a compiled form. English on `rule` is provenance only.
public struct TypedRulePreview: Sendable, Equatable, Codable {
    public var sentence: String
    public var rule: PolicyDocumentRule
    public var allowedToSave: Bool

    public init(sentence: String, rule: PolicyDocumentRule, allowedToSave: Bool) {
        self.sentence = sentence
        self.rule = rule
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
    case unsupportedPredicate
    case hardStop
}

public enum EnglishCompilerError: Error, Sendable, Equatable {
    case unavailable
}
