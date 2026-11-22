import Testing
import RVDomain
@testable import RVPolicy

/// Plain sentences draft without a model (F1: draft refused every sentence).
struct PlainEnglishRuleCompilerTests {
    private let compiler = PlainEnglishRuleCompiler()

    private func rule(_ sentence: String) -> PolicyDocumentRule? {
        guard case .rule(let preview) = compiler.draft(sentence) else {
            Issue.record("expected a rule for \(sentence), got \(compiler.draft(sentence))")
            return nil
        }
        #expect(preview.allowedToSave)
        #expect(preview.rule.english == sentence)
        return preview.rule
    }

    @Test(arguments: [
        "never force push to main",
        "never force-push to main",
        "never allow force-push to main",
        "Never force-push main.",
        "block git push --force origin main",
        "don't let agents force push to the main branch",
        "please never git push -f to main",
    ])
    func forcePushMain_isTheCanonicalRule(sentence: String) throws {
        let drafted = try #require(rule(sentence))
        #expect(drafted.verdict == .deny)
        #expect(drafted.predicate == .gitPush(force: .exactly(.force), branch: "main"))
        #expect(drafted.id == RuleID(pack: .typedGit, pattern: "force-push-main"))
        guard case .rule(let preview) = compiler.draft(sentence) else { return }
        #expect(preview.sentence == "Always block force-push to main")
    }

    @Test func askBeforePushingToRelease() throws {
        let drafted = try #require(rule("ask before pushing to release"))
        #expect(drafted.verdict == .ask)
        #expect(drafted.predicate == .gitPush(force: .any, branch: "release"))
    }

    @Test func pushToAnyBranch_hasNoBranch() throws {
        let drafted = try #require(rule("never force push to any branch"))
        #expect(drafted.predicate == .gitPush(force: .exactly(.force), branch: nil))
    }

    @Test func forceWithLease() throws {
        let drafted = try #require(rule("ask before push --force-with-lease to main"))
        #expect(drafted.predicate == .gitPush(force: .exactly(.forceWithLease), branch: "main"))
    }

    @Test func resetHard() throws {
        let drafted = try #require(rule("block git reset --hard"))
        #expect(drafted.verdict == .deny)
        #expect(drafted.predicate == .gitReset(mode: .hard))
        #expect(drafted.id == RuleID(pack: .typedGit, pattern: "reset-hard-deny"))
        #expect(try #require(rule("never hard reset")).predicate == .gitReset(mode: .hard))
    }

    @Test func gitClean_coversEveryClean() throws {
        #expect(try #require(rule("never git clean -fdx")).predicate == .gitClean(force: nil, directories: nil))
    }

    @Test func discard() throws {
        #expect(try #require(rule("ask before discarding uncommitted changes")).predicate
            == .gitDiscardWorktree(pathspec: nil))
        #expect(try #require(rule("never git checkout -- .")).predicate == .gitDiscardWorktree(pathspec: nil))
    }

    @Test func deletes() throws {
        let rmrf = try #require(rule("never rm -rf"))
        #expect(rmrf.predicate == .filesystemDelete(recursive: true, force: true))
        #expect(rmrf.id.rawValue == "typed.filesystem:delete-rf-deny")
        #expect(try #require(rule("ask before deleting files")).predicate
            == .filesystemDelete(recursive: nil, force: nil))
        #expect(try #require(rule("never delete files recursively")).predicate
            == .filesystemDelete(recursive: true, force: nil))
    }

    @Test func moves() throws {
        #expect(try #require(rule("ask before moving files")).predicate == .filesystemMove)
    }

    @Test func allow_draftsAnAllowRule() throws {
        let drafted = try #require(rule("allow force push to feature"))
        #expect(drafted.verdict == .allow)
    }

    @Test(arguments: [
        "never delete files outside this repo",
        "never let agents delete anything outside the repository",
        "block moving files outside this project",
    ])
    func outsideTheRepo_isAlreadyBuiltIn(sentence: String) {
        #expect(compiler.draft(sentence) == .builtIn(.outOfRepoWrite))
    }

    @Test func refusals_sayWhy() {
        func reason(_ sentence: String) -> (EnglishCompileRefusal, String)? {
            if case .refused(let refusal, let why) = compiler.draft(sentence) { return (refusal, why) }
            Issue.record("expected a refusal for \(sentence)")
            return nil
        }
        #expect(reason("   ")?.0 == .empty)
        #expect(reason("be careful in prod")?.0 == .uncompilable)
        #expect(reason("be careful in prod")?.1.contains("start with never") == true)
        #expect(reason("never npm publish")?.0 == .unsupportedPredicate)
        #expect(reason("never npm publish")?.1.contains("npm") == true)
        #expect(reason("never terraform destroy")?.0 == .unsupportedPredicate)
        #expect(reason("never push to release/*")?.1.contains("not a pattern") == true)
        #expect(reason("never force push to main on fridays")?.1.contains("\"fridays\"") == true)
        #expect(reason("never push and reset")?.1.contains("one command per rule") == true)
        #expect(reason("never delete branches")?.0 == .unsupportedPredicate)
        #expect(reason("never push except to feature")?.1.contains("exceptions") == true)
        #expect(reason("never be careful")?.0 == .uncompilable)
    }

    @Test func compile_mapsDraftsOntoTheProtocol() async throws {
        #expect(try await compiler.compile("never delete files outside this repo") == .refuse(.alreadyBuiltIn))
        #expect(try await compiler.compile("") == .refuse(.empty))
        guard case .preview = try await compiler.compile("never force push to main") else {
            Issue.record("expected a preview")
            return
        }
    }

    /// Whatever the verdict, a drafted rule is a typed rule, and typed rules
    /// are restrict-only: an allow never turns a deny into an allow.
    @Test func draftedAllow_neverLoosensAPackDeny() throws {
        let drafted = try #require(rule("allow force push to main"))
        let typed = drafted.typedRule(origin: .machine)
        let deny = ActionPolicyEngine.typedRestriction(
            .git(.push(remote: "origin", refspec: "main", force: .force)), rules: [typed])
        #expect(deny == nil)
    }
}
