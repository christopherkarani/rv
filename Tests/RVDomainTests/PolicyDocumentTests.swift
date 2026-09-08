import Testing
import RVDomain

struct PolicyDocumentTests {
    @Test func typedRule_dropsEnglish() {
        let row = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "force-push-main"),
            verdict: .deny,
            predicate: .gitPush(force: .force, branch: "main"),
            english: "Never allow force-push to main"
        )
        #expect(row.english == "Never allow force-push to main")
        let typed = row.typedRule(origin: .machine)
        #expect(typed.id == row.id)
        #expect(typed.predicate == row.predicate)
        #expect(typed.verdict == .deny)
        #expect(typed.origin == .machine)
    }

    @Test func emptyEnglish_becomesNil() {
        let row = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "force-push-main"),
            verdict: .deny,
            predicate: .gitPush(force: .force, branch: "main"),
            english: "   "
        )
        #expect(row.english == nil)
    }

    @Test func document_mapsRulesWithOrigin() {
        let document = PolicyDocument(
            rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                    verdict: .deny,
                    predicate: .gitPush(force: .force, branch: "main"),
                    english: "Never allow force-push to main"
                ),
            ]
        )
        let rules = document.typedRules(origin: .repo)
        #expect(rules.count == 1)
        #expect(rules[0].origin == .repo)
        #expect(rules[0].predicate == .gitPush(force: .force, branch: "main"))
    }
}
