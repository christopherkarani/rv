import Testing
import RVDomain
@testable import RVPolicy

struct FoundationModelsEnglishCompileMappingTests {
    @Test func emptySentence_usesDefaultForcePushMainDenyID() {
        let result = FoundationModelsEnglishCompileMapping.preview(
            force: .exactly(.force),
            branch: "main",
            verdict: .deny,
            sentence: "",
            english: "never allow force-push to main"
        )
        guard case .preview(let preview) = result else {
            Issue.record("expected preview, got \(result)")
            return
        }
        #expect(preview.sentence == "Always block force-push to main")
        #expect(preview.allowedToSave)
        #expect(preview.rule.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
        #expect(preview.rule.predicate == .gitPush(force: .exactly(.force), branch: "main"))
        #expect(preview.rule.verdict == .deny)
        #expect(preview.rule.english == "never allow force-push to main")
    }

    @Test func providedSentence_isKeptAndGenericRuleID() {
        let result = FoundationModelsEnglishCompileMapping.preview(
            force: .exactly(.force),
            branch: "main",
            verdict: .allow,
            sentence: "Always allow force-push to main"
        )
        guard case .preview(let preview) = result else {
            Issue.record("expected preview")
            return
        }
        #expect(preview.sentence == "Always allow force-push to main")
        #expect(preview.rule.id == RuleID(pack: .typedGit, pattern: "git-push-force-main-allow"))
        #expect(preview.rule.english == nil)
    }

    @Test func anyForceNilBranch_defaultSentences() {
        let deny = FoundationModelsEnglishCompileMapping.preview(
            force: .any,
            branch: nil,
            verdict: .deny,
            sentence: ""
        )
        let allow = FoundationModelsEnglishCompileMapping.preview(
            force: .exactly(.none),
            branch: nil,
            verdict: .allow,
            sentence: ""
        )
        let ask = FoundationModelsEnglishCompileMapping.preview(
            force: .exactly(.forceWithLease),
            branch: nil,
            verdict: .ask,
            sentence: ""
        )
        #expect(sentence(deny) == "Always block git push to any branch")
        #expect(sentence(allow) == "Always allow git push to any branch")
        #expect(sentence(ask) == "Ask before git push to any branch")
        #expect(rulePattern(deny) == "git-push-deny")
        #expect(rulePattern(allow) == "git-push-none-allow")
        #expect(rulePattern(ask) == "git-push-forceWithLease-ask")
    }

    @Test func exactForce_defaultSentencesForEachVerdict() {
        let deny = FoundationModelsEnglishCompileMapping.preview(
            force: .exactly(.force),
            branch: "develop",
            verdict: .deny,
            sentence: ""
        )
        let allow = FoundationModelsEnglishCompileMapping.preview(
            force: .exactly(.force),
            branch: "develop",
            verdict: .allow,
            sentence: ""
        )
        let ask = FoundationModelsEnglishCompileMapping.preview(
            force: .exactly(.force),
            branch: "develop",
            verdict: .ask,
            sentence: ""
        )
        #expect(sentence(deny) == "Always block force-push to develop")
        #expect(sentence(allow) == "Always allow force-push to develop")
        #expect(sentence(ask) == "Ask before force-push to develop")
        #expect(rulePattern(deny) == "git-push-force-develop-deny")
        #expect(rulePattern(allow) == "git-push-force-develop-allow")
        #expect(rulePattern(ask) == "git-push-force-develop-ask")
    }

    @Test func anyForceNamedBranch_askSentence() {
        let result = FoundationModelsEnglishCompileMapping.preview(
            force: .any,
            branch: "release",
            verdict: .ask,
            sentence: ""
        )
        #expect(sentence(result) == "Ask before git push to release")
        #expect(rulePattern(result) == "git-push-release-ask")
    }
}

private func sentence(_ result: EnglishCompileResult) -> String? {
    guard case .preview(let preview) = result else { return nil }
    return preview.sentence
}

private func rulePattern(_ result: EnglishCompileResult) -> String? {
    guard case .preview(let preview) = result else { return nil }
    return preview.rule.id.pattern
}
