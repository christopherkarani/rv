import Testing
import RVDomain
import RVPolicy

struct PolicyDocumentTOMLTests {
    @Test func roundTripsGitPushDeny() throws {
        let source = """
        schema_version = 1

        [[rule]]
        id = "typed.git:force-push-main"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        branch = "main"
        english = "Never allow force-push to main"
        """
        let document = try PolicyDocumentTOML.parse(source)
        #expect(document.schemaVersion == 1)
        #expect(document.rules.count == 1)
        let rule = document.rules[0]
        #expect(rule.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
        #expect(rule.verdict == .deny)
        #expect(rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(rule.english == "Never allow force-push to main")
        let typed = rule.typedRule(origin: .machine)
        #expect(typed.predicate == rule.predicate)
        let rendered = PolicyDocumentTOML.render(document)
        let again = try PolicyDocumentTOML.parse(rendered)
        #expect(again == document)
    }

    @Test func unknownKey_refuses() {
        let source = """
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitPush"
        pattern = "git push -f"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }

    @Test func missingPredicate_refuses() {
        let source = """
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        english = "Never force-push main"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }

    @Test func unknownPredicate_refuses() {
        let source = """
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitStatus"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }

    @Test func wrongSchemaVersion_refuses() {
        let source = """
        schema_version = 2
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitPush"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }

    @Test func duplicateId_refuses() {
        let source = """
        schema_version = 1
        [[rule]]
        id = "typed.git:same"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        branch = "main"
        [[rule]]
        id = "typed.git:same"
        verdict = "ask"
        predicate = "gitPush"
        force = "force"
        branch = "develop"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }

    @Test func newlineEnglish_roundTripsAsSingleLine() throws {
        let document = PolicyDocument(
            rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                    verdict: .deny,
                    predicate: .gitPush(force: .force, branch: "main"),
                    english: "Never allow\nforce-push to main"
                ),
            ]
        )
        let rendered = PolicyDocumentTOML.render(document)
        #expect(rendered.contains("\nforce-push") == false)
        let again = try PolicyDocumentTOML.parse(rendered)
        #expect(again.rules[0].english == "Never allow force-push to main")
    }

    @Test func duplicatePredicate_refuses() {
        let source = """
        schema_version = 1
        [[rule]]
        id = "typed.git:a"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        branch = "main"
        [[rule]]
        id = "typed.git:b"
        verdict = "ask"
        predicate = "gitPush"
        force = "force"
        branch = "main"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }

    @Test func mergeLayer_keepsTighterVerdict() {
        let allow = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "allow"),
            verdict: .allow,
            predicate: .gitPush(force: .force, branch: "main")
        )
        let deny = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "deny"),
            verdict: .deny,
            predicate: .gitPush(force: .force, branch: "main"),
            english: "Never allow force-push to main"
        )
        let merged = PolicyDocumentTOML.mergeLayer(existing: [allow], incoming: [deny])
        #expect(merged == [deny])
        let unchanged = PolicyDocumentTOML.mergeLayer(existing: [deny], incoming: [allow])
        #expect(unchanged == [deny])
    }
}
