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
        #expect(rule.predicate == .gitPush(force: .exactly(.force), branch: "main"))
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
                    predicate: .gitPush(force: .exactly(.force), branch: "main"),
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

    @Test func additiveSafetyAndAllowPaths_roundTrip() throws {
        let source = """
        schema_version = 1
        safety.level = "strict"
        secret.allow_paths = [".env", "config/secrets"]
        """
        let document = try PolicyDocumentTOML.parse(source)
        #expect(document.safetyLevel == .strict)
        #expect(document.allowPaths == [".env", "config/secrets"])
        let again = try PolicyDocumentTOML.parse(PolicyDocumentTOML.render(document))
        #expect(again == document)
    }

    @Test func mergeLayer_keepsTighterVerdict() {
        let allow = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "allow"),
            verdict: .allow,
            predicate: .gitPush(force: .exactly(.force), branch: "main")
        )
        let deny = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "deny"),
            verdict: .deny,
            predicate: .gitPush(force: .exactly(.force), branch: "main"),
            english: "Never allow force-push to main"
        )
        let merged = PolicyDocumentTOML.mergeLayer(existing: [allow], incoming: [deny])
        #expect(merged == [deny])
        let unchanged = PolicyDocumentTOML.mergeLayer(existing: [deny], incoming: [allow])
        #expect(unchanged == [deny])
    }

    @Test func omittedForce_isAny_distinctFromForceNone() throws {
        let omitted = """
        schema_version = 1

        [[rule]]
        id = "typed.git:any-push-main"
        verdict = "deny"
        predicate = "gitPush"
        branch = "main"
        """
        let none = """
        schema_version = 1

        [[rule]]
        id = "typed.git:non-force-main"
        verdict = "deny"
        predicate = "gitPush"
        force = "none"
        branch = "main"
        """
        let omittedDocument = try PolicyDocumentTOML.parse(omitted)
        let noneDocument = try PolicyDocumentTOML.parse(none)
        #expect(omittedDocument.rules[0].predicate == .gitPush(force: .any, branch: "main"))
        #expect(noneDocument.rules[0].predicate == .gitPush(force: .exactly(.none), branch: "main"))
        #expect(omittedDocument.rules[0].predicate != noneDocument.rules[0].predicate)
        let omittedRendered = PolicyDocumentTOML.render(omittedDocument)
        let noneRendered = PolicyDocumentTOML.render(noneDocument)
        #expect(omittedRendered.contains("force =") == false)
        #expect(noneRendered.contains("force = \"none\""))
        #expect(try PolicyDocumentTOML.parse(omittedRendered) == omittedDocument)
        #expect(try PolicyDocumentTOML.parse(noneRendered) == noneDocument)
    }

    @Test func wave1Predicates_roundTrip() throws {
        let document = PolicyDocument(
            rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "discard"),
                    verdict: .ask,
                    predicate: .gitDiscardWorktree(pathspec: nil)
                ),
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "reset-hard"),
                    verdict: .deny,
                    predicate: .gitReset(mode: .hard)
                ),
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "clean-fd"),
                    verdict: .ask,
                    predicate: .gitClean(force: true, directories: true)
                ),
                PolicyDocumentRule(
                    id: RuleID(pack: .coreFilesystem, pattern: "rm-rf"),
                    verdict: .deny,
                    predicate: .filesystemDelete(recursive: true, force: true)
                ),
                PolicyDocumentRule(
                    id: RuleID(pack: .coreFilesystem, pattern: "mv"),
                    verdict: .ask,
                    predicate: .filesystemMove
                ),
            ]
        )
        let rendered = PolicyDocumentTOML.render(document)
        #expect(rendered.contains("predicate = \"gitDiscardWorktree\""))
        #expect(rendered.contains("flag_force = \"true\""))
        #expect(rendered.contains("directories = \"true\""))
        #expect(rendered.contains("recursive = \"true\""))
        #expect(rendered.contains("predicate = \"filesystemMove\""))
        #expect(try PolicyDocumentTOML.parse(rendered) == document)
    }

    @Test func unknownFlagForce_refuses() {
        let source = """
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "ask"
        predicate = "gitClean"
        flag_force = "yes"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }

    @Test func unknownForce_refuses() {
        let source = """
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        predicate = "gitPush"
        force = "withLeaseMaybe"
        branch = "main"
        """
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentTOML.parse(source)
        }
    }
}
