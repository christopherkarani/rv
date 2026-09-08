import Foundation
import Testing
import RVDomain

@Suite("EnglishCompilerTests")
struct EnglishCompilerTests {
    @Test func compile_neverAllowForcePushMain_yieldsGitPushDenyPreview() async throws {
        let compiler = StubEnglishCompiler()
        let result = try await compiler.compile("never allow force-push to main")
        guard case .preview(let preview) = result else {
            Issue.record("expected preview, got \(result)")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.rule.verdict == .deny)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence == "Always block force-push to main")
        #expect(preview.rule.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
    }

    @Test func compile_beCarefulInProd_refusesUncompilable() async throws {
        let compiler = StubEnglishCompiler()
        let result = try await compiler.compile("be careful in prod")
        #expect(result == .refuse(.uncompilable))
    }

    @Test func compile_emptyEnglish_refusesEmpty() async throws {
        let compiler = StubEnglishCompiler()
        let result = try await compiler.compile("")
        #expect(result == .refuse(.empty))
    }

    @Test func previewDraft_isTypedRuleNotEnglish() throws {
        let preview = TypedRulePreview(
            sentence: "Always block force-push to main",
            rule: PolicyDocumentRule(
                id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                verdict: .deny,
                predicate: .gitPush(force: .force, branch: "main")
            ),
            allowedToSave: true
        )
        let data = try JSONEncoder().encode(preview)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("gitPush") == true)
        #expect(json.contains("\"verdict\":\"deny\"") == true)
        let decoded = try JSONDecoder().decode(TypedRulePreview.self, from: data)
        #expect(decoded == preview)
    }

    @Test func unavailableCompiler_throwsUnavailable() async {
        let compiler = UnavailableEnglishCompiler()
        await #expect(throws: EnglishCompilerError.unavailable) {
            _ = try await compiler.compile("never allow force-push to main")
        }
    }

    @Test func compile_isInvokedThroughProtocolExistential() async throws {
        let compiler: any EnglishCompiler = StubEnglishCompiler()
        let result = try await compiler.compile("never allow force-push to main")
        guard case .preview = result else {
            Issue.record("expected preview through any EnglishCompiler")
            return
        }
    }
}

private struct StubEnglishCompiler: EnglishCompiler {
    func compile(_ english: String) async throws -> EnglishCompileResult {
        if english.isEmpty {
            return .refuse(.empty)
        }
        if english == "never allow force-push to main" {
            return .preview(
                TypedRulePreview(
                    sentence: "Always block force-push to main",
                    rule: PolicyDocumentRule(
                        id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                        verdict: .deny,
                        predicate: .gitPush(force: .force, branch: "main")
                    ),
                    allowedToSave: true
                )
            )
        }
        return .refuse(.uncompilable)
    }
}

private struct UnavailableEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        throw EnglishCompilerError.unavailable
    }
}
