import Testing
import RVDomain

@Suite("EnglishRefuseTests")
struct EnglishRefuseTests {
    @Test func compile_emptyEnglish_refusesEmpty() async throws {
        let result = try await FakeEnglishCompiler().compile("")
        #expect(result == .refuse(.empty))
    }

    @Test(arguments: [
        "npm publish",
        "mcp__linear__save_issue",
    ])
    func compile_deferredAnalyzerEnglish_refusesUnsupported(_ english: String) async throws {
        let result = try await FakeEnglishCompiler().compile(english)
        #expect(result == .refuse(.unsupported))
    }

    @Test(arguments: [
        "",
        "npm publish",
        "mcp__linear__save_issue",
        "be careful in prod",
    ])
    func compile_refuseEnglish_leavesRuleStoreUnchanged(_ english: String) async throws {
        let existing = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: .gitPush(force: .force, branch: "main"),
            verdict: .deny,
            origin: .machine
        )
        var store = [existing]
        let result = try await FakeEnglishCompiler().compile(english)
        if case .preview(let preview) = result {
            Issue.record("refuse English must not yield a preview")
            if preview.allowedToSave {
                store.append(preview.draft)
            }
        }
        #expect(store == [existing])
    }
}
