/// Deterministic English → gitPush form. Empty, npm, mcp, and unknown refuse.
/// Not a model. Tests and CLI inject this; AFM stays in RVPolicy.
public struct FakeEnglishCompiler: EnglishCompiler {
    public init() {}

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .refuse(.empty)
        }
        switch trimmed {
        case "never force-push main", "never allow force-push to main":
            return .preview(Self.forcePushMainDeny(english: trimmed))
        case "npm publish", "mcp__linear__save_issue":
            return .refuse(.unsupported)
        case "git status":
            return .refuse(.unsupportedPredicate)
        default:
            return .refuse(.uncompilable)
        }
    }

    private static func forcePushMainDeny(english: String) -> TypedRulePreview {
        TypedRulePreview(
            sentence: "Always block force-push to main",
            rule: PolicyDocumentRule(
                id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                verdict: .deny,
                predicate: .gitPush(force: .force, branch: "main"),
                english: english
            ),
            allowedToSave: true
        )
    }
}
