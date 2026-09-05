/// Deterministic English → gitPush form. Empty, npm, mcp, and unknown refuse.
/// Not a model. Tests and CLI inject this; AFM stays in RVPolicy.
public struct FakeEnglishCompiler: EnglishCompiler {
    public init() {}

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        if english.isEmpty {
            return .refuse(.empty)
        }
        switch english {
        case "never force-push main", "never allow force-push to main":
            return .preview(Self.forcePushMainDeny)
        case "npm publish", "mcp__linear__save_issue":
            return .refuse(.unsupported)
        default:
            return .refuse(.uncompilable)
        }
    }

    private static let forcePushMainDeny = RulePreview(
        sentence: "Always block force-push to main.",
        draft: TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: .gitPush(force: .force, branch: "main"),
            verdict: .deny,
            origin: .machine
        ),
        allowedToSave: true
    )
}
