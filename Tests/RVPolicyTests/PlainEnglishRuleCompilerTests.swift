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

    /// Review of #669: the preview describes the rule it saves, which
    /// covers --force-with-lease and not plain --force.
    @Test func forceWithLease_previewSaysWhatItCovers() {
        guard case .rule(let preview) = compiler.draft("never push --force-with-lease to main") else {
            Issue.record("expected a rule")
            return
        }
        #expect(preview.sentence == "Always block git push --force-with-lease to main (not plain --force)")
        guard case .rule(let any) = compiler.draft("never push to main") else {
            Issue.record("expected a rule")
            return
        }
        #expect(any.sentence == "Always block git push to main, forced or not")
    }

    @Test func resetHard() throws {
        let drafted = try #require(rule("block git reset --hard"))
        #expect(drafted.verdict == .deny)
        #expect(drafted.predicate == .gitReset(mode: .hard))
        #expect(drafted.id == RuleID(pack: .typedGit, pattern: "reset-hard-deny"))
        #expect(try #require(rule("never hard reset")).predicate == .gitReset(mode: .hard))
    }

    @Test func gitClean_flags() throws {
        #expect(try #require(rule("never git clean")).predicate == .gitClean(force: nil, directories: nil))
        #expect(try #require(rule("never git clean -fd")).predicate == .gitClean(force: true, directories: true))
        #expect(try #require(rule("ask before git clean -f")).predicate == .gitClean(force: true, directories: nil))
        guard case .rule(let every) = compiler.draft("never git clean") else { return }
        #expect(every.sentence == "Always block every git clean")
    }

    /// Review of #669: a clean flag the predicate can't hold is refused, not
    /// dropped into a rule that covers every git clean.
    @Test(arguments: ["ask before git clean --dry-run", "never git clean -n", "never git clean -fdx"])
    func gitClean_otherFlags_refuse(sentence: String) {
        guard case .refused(.unsupportedPredicate, let why) = compiler.draft(sentence) else {
            Issue.record("expected a refusal for \(sentence), got \(compiler.draft(sentence))")
            return
        }
        #expect(why.contains("can't single out git clean"))
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
        #expect(drafted.predicate == .gitPush(force: .exactly(.force), branch: "feature"))
    }

    /// Review of #669: a word in the branch slot is the branch, never filler,
    /// and a hyphenated branch stays whole.
    @Test(arguments: [
        ("never force push to work", "work"),
        ("never push the work branch", "work"),
        ("never force push to work-in-progress", "work-in-progress"),
        ("never force-push to release-1.2", "release-1.2"),
        ("never let anyone force push to main", "main"),
        ("never force push to origin/main", "main"),
        ("never git push -f upstream main", "main"),
    ])
    func branchSlot_keepsTheBranch(sentence: String, branch: String) throws {
        guard case .gitPush(_, let found) = try #require(rule(sentence)).predicate else {
            Issue.record("expected a push rule")
            return
        }
        #expect(found == branch)
    }

    @Test func remotePrefix_isNamedInThePreview() {
        guard case .rule(let preview) = compiler.draft("never force push to origin/main") else {
            Issue.record("expected a rule")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .exactly(.force), branch: "main"))
        #expect(preview.sentence == "Always block force-push to main (origin/main read as branch main)")
    }

    /// Review of #669: nothing a sentence says may be dropped into a wider rule.
    @Test(arguments: [
        ("never push tags", "\"tags\" is not a branch"),
        ("never push secrets", "\"secrets\" is not a branch"),
        ("never push commits", "\"commits\" is not a branch"),
        ("never force push to the local branch", "\"local\" doesn't name a branch"),
        ("never force push to my branch", "\"my\" doesn't name a branch"),
        ("never push --tags", "can't single out --tags"),
        ("never push to main or release", "one thing per rule"),
        ("never delete the project", "\"project\""),
        ("never delete my uncommitted changes", "never discard uncommitted changes"),
        ("never reset my local changes", "never discard uncommitted changes"),
        ("never delete folders", "\"folders\""),
        ("never git rm", "git rm"),
        ("never rm -rfv", "can't single out rm -rfv"),
        ("ask before moving files into the trash", "\"trash\""),
    ])
    func wordsThatWouldWidenTheRule_refuse(sentence: String, reason: String) {
        guard case .refused(_, let why) = compiler.draft(sentence) else {
            Issue.record("expected a refusal for \(sentence), got \(compiler.draft(sentence))")
            return
        }
        #expect(why.contains(reason), "\(sentence): \(why)")
    }

    @Test(arguments: [
        "never delete files outside this repo",
        "never let agents delete anything outside the repository",
        "block moving files outside this project",
        "never rm -rf outside of the working directory",
    ])
    func outsideTheRepo_isAlreadyBuiltIn(sentence: String) {
        #expect(compiler.draft(sentence) == .builtIn(.outOfRepoWrite))
    }

    /// Review of #669: neither of these is "already on".
    @Test func outside_allowOrAPath_refuses() {
        guard case .refused(_, let allow) = compiler.draft("allow rm -rf outside the repo") else {
            Issue.record("expected a refusal")
            return
        }
        #expect(allow.contains("an allow rule can't let through what rv stops"))
        guard case .refused(_, let path) = compiler.draft("never delete outside of node_modules") else {
            Issue.record("expected a refusal")
            return
        }
        #expect(path.contains("can't name a path"))
    }

    @Test func refusals_sayWhy() {
        func reason(_ sentence: String) -> (EnglishCompileRefusal, String)? {
            switch compiler.draft(sentence) {
            case .refused(let refusal, let why): return (refusal, why)
            case .unreadable(let why): return (.uncompilable, why)
            default:
                Issue.record("expected a refusal for \(sentence)")
                return nil
            }
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

    /// Only "can't tell which command" may go to a model; everything the
    /// grammar read and refused is final.
    @Test func unreadable_onlyWhenNoVerdictOrNoCommand() {
        let unreadable = ["be careful in prod", "never be careful", "keep main safe from forced history rewrites"]
        for sentence in unreadable {
            guard case .unreadable = compiler.draft(sentence) else {
                Issue.record("expected unreadable for \(sentence), got \(compiler.draft(sentence))")
                continue
            }
        }
        let final = [
            "never force push to main on fridays", "never push except to feature", "never push and reset",
            "never npm publish", "never push tags",
        ]
        for sentence in final {
            guard case .refused = compiler.draft(sentence) else {
                Issue.record("expected a final refusal for \(sentence), got \(compiler.draft(sentence))")
                continue
            }
        }
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
