import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
import RVPresentation
import RVTheme
@testable import RVCLI

/// F1 policy bugs: draft drafts plain sentences, errors say line and fix,
/// a missing file fails, explain shows the person's own rule, typed allow
/// says it is restrict-only.
struct PolicyF1CommandTests {
    private func scratch() throws -> (HomeDirectory, URL) {
        let home = try isolatedHome()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-f1-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (home, workspace)
    }

    private func cleanup(_ home: HomeDirectory, _ workspace: URL) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: home.rawValue, isDirectory: true))
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: draft

    @Test func draft_positionalSentence_printsTheRule() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, workspacePath: workspace.path, englishCompiler: PlainEnglishRuleCompiler(), output: out
        ) {
            try await PolicyDraftCommand.parse(["never force push to main"]).run()
        }
        #expect(out.stdout == "  ✕ never git push --force → main\n  typed.git:force-push-main\n")
    }

    /// The preview line the artifact shows: glyph and verb, command, → branch,
    /// then the rule id. Predicate fields stay in --json.
    @Test(arguments: [
        ("never force push to main", "  ✕ never git push --force → main\n  typed.git:force-push-main"),
        ("ask before pushing to release", "  ◐ ask git push → release\n  typed.git:git-push-release-ask"),
        ("ask before push --force-with-lease to main",
         "  ◐ ask git push --force-with-lease → main\n  typed.git:git-push-forceWithLease-main-ask"),
        ("never force push to origin/main",
         "  ✕ never git push --force → main · origin/main read as branch main\n  typed.git:force-push-main"),
        ("it is fine to force push to main",
         "  ✓ allow git push --force → main\n  typed.git:git-push-force-main-allow\n"
            + "  allow only narrows: it never lets through what rv or a pack stops"),
        ("under no circumstances force push to main", "  ✕ never git push --force → main\n  typed.git:force-push-main"),
        ("block git reset --hard", "  ✕ never git reset --hard\n  typed.git:reset-hard-deny"),
        ("never rm -rf", "  ✕ never rm -rf\n  typed.filesystem:delete-rf-deny"),
    ])
    func draft_previewLine_matchesTheArtifact(english: String, expected: String) async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: english, save: false, robot: false, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler())
        #expect(result.text == expected)
    }

    @Test func draft_previewGlyph_usesTheVocabularyColours() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let palette = Palette(for: ColorCapability(colorsEnabled: true))
        for (english, ink, glyph) in [
            ("never force push to main", palette.deny, "✕"), ("ask before pushing to release", palette.mark, "◐"),
            ("allow force push to main", palette.allow, "✓"),
        ] {
            let result = try await PolicyDraftRun.execute(
                english: english, save: false, robot: false, home: home, workspace: workspace,
                compiler: PlainEnglishRuleCompiler(), palette: palette)
            #expect(result.text.hasPrefix("  " + ink + glyph + palette.reset + " "), "\(english)")
            #expect(result.text.contains(palette.muted + "→" + palette.reset))
        }
    }

    @Test func draft_sentenceGivenTwice_isAUsageError() {
        #expect(throws: (any Error).self) {
            try PolicyDraftCommand.parseAsRoot(["never push", "--english", "never push"])
        }
    }

    @Test func draft_refusal_saysWhatIsWrongThenTheFix() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: "never npm publish", save: false, robot: false, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler())
        #expect(result.outcome == .refuse(.unsupportedPredicate))
        #expect(result.text == """
              ✕ a rule can't cover npm yet
              → drafts cover git push, reset, clean and restore, and deleting or moving files
            """)
    }

    /// Mac check of #669: "every no has a next". The exact refusal text for
    /// a look-alike branch and for a sentence the grammar can't read.
    @Test(arguments: [
        ("never force push to m\u{0430}in", """
              ✕ can't read that: branch name has non-ASCII characters (m\u{0430}in)
              → type it in plain ASCII
            """),
        ("be careful in prod", """
              ✕ can't read that: no never, ask or allow at the start
              → start with never, ask before, or allow, like "never force-push to main"
            """),
        ("", """
              ✕ nothing to draft
              → say a rule, like "never force-push to main"
            """),
        ("never delete branches", """
              ✕ a rule can't cover deleting branches yet
              → try: rv policy draft "never force-push to main"
            """),
    ])
    func draft_refusalText(english: String, expected: String) async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: english, save: false, robot: false, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler())
        #expect(result.text == expected)
    }

    /// Every refusal ends with a → line, and the ✕ is red in colour.
    @Test(arguments: [
        "never npm publish", "never force push to main on fridays", "never push and reset", "never push tags",
        "never push except to feature", "never force push to", "never push to release/*", "never delete the project",
        "allow rm -rf outside the repo", "never delete outside of node_modules", "never git clean -n",
        "never push --force --force-with-lease to main", "never be careful", "",
    ])
    func draft_everyRefusal_endsWithANext(english: String) async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let palette = Palette(for: ColorCapability(colorsEnabled: true))
        let plain = try await PolicyDraftRun.execute(
            english: english, save: false, robot: false, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler())
        let lines = plain.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "\(plain.text)")
        #expect(lines.first?.hasPrefix("  ✕ ") == true, "\(plain.text)")
        #expect(lines.last?.hasPrefix("  → ") == true, "\(plain.text)")
        let coloured = try await PolicyDraftRun.execute(
            english: english, save: false, robot: false, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler(), palette: palette)
        #expect(coloured.text.hasPrefix("  " + palette.deny + "✕" + palette.reset + " "), "\(english)")
        // --json is unchanged: refuse and reason.
        let robot = try await PolicyDraftRun.execute(
            english: english, save: false, robot: true, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler())
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(robot.text.utf8)) as? [String: String], "\(robot.text)")
        #expect(Set(object.keys) == ["refuse", "reason"])
    }

    /// Mac recheck of #669: --json on a refusal carries the reason.
    @Test func draft_jsonRefusal_carriesTheReason() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: "never npm publish", save: false, robot: true, home: home, workspace: workspace,
            compiler: EnglishCompileChain(
                primary: FakeEnglishCompiler(), fallback: FakeEnglishCompiler(), phrases: PlainEnglishRuleCompiler()))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: String], "\(result.text)")
        #expect(object["refuse"] == "unsupportedPredicate")
        #expect(object["reason"]?.hasPrefix("a rule can't cover npm yet") == true, "\(result.text)")
    }

    @Test func draft_modelRuleThatDisagrees_saysWhy() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: "force pushing to main is forbidden", save: true, robot: false, home: home,
            workspace: workspace,
            compiler: EnglishCompileChain(
                primary: NoForceModel(), fallback: FakeEnglishCompiler(), phrases: PlainEnglishRuleCompiler()))
        #expect(result.outcome == .refuse(.uncompilable))
        #expect(result.text.hasPrefix("  ✕ can't read this sentence for sure: it says force-push"),
            "\(result.text)")
        #expect(FileManager.default.fileExists(
            atPath: TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home)).machineFileURL.path) == false)
    }

    @Test func draft_modelRefusalStillGetsAReason() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        // A compiler that only says "uncompilable" for a sentence the grammar reads
        // as a vague one still prints the grammar's reason.
        let result = try await PolicyDraftRun.execute(
            english: "be careful in prod", save: false, robot: false, home: home, workspace: workspace,
            compiler: FakeEnglishCompiler())
        #expect(result.text.hasPrefix("  ✕ can't read that: no never, ask or allow at the start\n  → start with never"))
    }

    @Test func draft_outsideTheRepo_isAlreadyOn() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: "never delete files outside this repo", save: true, robot: false, home: home,
            workspace: workspace, compiler: PlainEnglishRuleCompiler())
        #expect(result.alreadyOn)
        #expect(result.text == "✓ Already on: rv stops deletes and moves outside this repo "
            + "(builtin.action:out-of-repo-write). Nothing to save.")
        #expect(FileManager.default.fileExists(
            atPath: TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home)).machineFileURL.path) == false)
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, workspacePath: workspace.path, englishCompiler: PlainEnglishRuleCompiler(), output: out
        ) {
            // Exit 0: nothing went wrong, there is just nothing to add.
            try await PolicyDraftCommand.parse(["never delete files outside this repo"]).run()
        }
    }

    @Test func draft_allowRule_saysItIsRestrictOnly() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: "allow force push to main", save: false, robot: false, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler())
        #expect(result.text == """
              ✓ allow git push --force → main
              typed.git:git-push-force-main-allow
              allow only narrows: it never lets through what rv or a pack stops
            """)
    }

    // MARK: validate / apply errors

    @Test func validate_badVerdict_printsLineAndFix_exit2() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let file = workspace.appendingPathComponent("c.toml")
        try "schema_version = 1\n[[rule]]\nid = \"typed.git:x\"\nverdict = \"block\"\npredicate = \"gitPush\"\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, workspacePath: workspace.path, output: out) {
            await #expect(throws: ExitCode(2)) {
                try Policy.Validate.parse([file.path]).run()
            }
        }
        #expect(out.stderr == "  ✕ \(file.path):4  verdict \"block\" is not a verdict\n  → use one of: deny, ask, allow\n")
    }

    @Test func validate_missingFile_exit2() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, workspacePath: workspace.path, output: out) {
            await #expect(throws: ExitCode(2)) {
                try Policy.Validate.parse(["nope.toml"]).run()
            }
        }
        #expect(out.stderr == "  ✕ No file at nope.toml\n")
    }

    @Test func validate_machineFile_namesTheFileUnderHome() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let store = TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: store.machineFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "schema_version = 1\nsafety.level = \"high\"\n".write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, workspacePath: workspace.path, output: out) {
            await #expect(throws: ExitCode(2)) {
                try Policy.Validate.parse([]).run()
            }
        }
        #expect(out.stderr.contains("~/.config/rv/policy.toml:2  safety.level \"high\" is not a level"), "\(out.stderr)")
        #expect(out.stderr.contains("→ use one of: normal, strict"), "\(out.stderr)")
    }

    @Test func apply_missingFile_saysNoFile() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, workspacePath: workspace.path, output: out) {
            await #expect(throws: ExitCode(1)) {
                try await Policy.Apply.parse(["absent.toml"]).run()
            }
        }
        #expect(out.stderr == "  ✕ No file at absent.toml\n")
    }

    @Test func ceilingCheck_namedBrokenFile_failsEvenWithoutACeiling() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let file = workspace.appendingPathComponent("c.toml")
        try "schema_version = 1\n[[rule]]\nverdict = \"deny\"\n".write(to: file, atomically: true, encoding: .utf8)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, workspacePath: workspace.path, output: out) {
            var check = try PolicyCheck.parse(["--ceiling", file.path])
            await #expect(throws: ExitCode(2)) { try await check.run() }
        }
        #expect(out.stderr.contains(":2  this [[rule]] has no id"), "\(out.stderr)")
    }

    // MARK: explain

    @Test func explain_listsTheTypedRuleThePackHid() {
        let push = SemanticAction.git(.push(remote: "origin", refspec: "main", force: .force))
        let forcePushMain = TypedRule(
            id: RuleID(pack: .typedGit, pattern: "force-push-main"),
            predicate: .gitPush(force: .exactly(.force), branch: "main"), verdict: .deny, origin: .repo)
        let resetHard = TypedRule(
            id: RuleID(pack: .typedGit, pattern: "reset-hard-deny"),
            predicate: .gitReset(mode: .hard), verdict: .deny, origin: .machine)
        let rules: [(TypedRule, ExplainAlsoMatch.Source)] = [(forcePushMain, .repo), (resetHard, .machine)]
        let packRule = RuleID(pack: .coreGit, pattern: "push-force-long")
        let found = ExplainTypedRules.matches(rules: rules, action: push, decidedBy: packRule)
        #expect(found == [ExplainAlsoMatch(ruleID: forcePushMain.id, source: .repo, verdict: .deny)])
        #expect(found.first?.label == "Your rule")
        #expect(found.first?.display == "typed.git:force-push-main · this repo (.rv/policy.toml) · deny")
        // The rule that decided is already on the Rule line.
        #expect(ExplainTypedRules.matches(rules: rules, action: push, decidedBy: forcePushMain.id) == [])
        #expect(ExplainTypedRules.matches(rules: rules, action: nil, decidedBy: packRule) == [])
    }

    /// Review of #669: an owner-ceiling rule is not "Your rule · this machine".
    @Test func explain_ceilingRule_isLabelledCeiling() {
        let match = ExplainAlsoMatch(
            ruleID: RuleID(pack: .typedGit, pattern: "no-force-push"), source: .ceiling, verdict: .deny)
        #expect(match.label == "Ceiling")
        #expect(match.display == "typed.git:no-force-push · owner ceiling (~/.config/rv/ceiling.toml) · deny")
    }

    @Test func explain_typedAllow_saysRestrictOnly() {
        let match = ExplainAlsoMatch(ruleID: RuleID(pack: .typedGit, pattern: "allow-main"), source: .machine, verdict: .allow)
        #expect(match.display.contains("allow is restrict-only"))
    }

    private func explainForcePushMain(json: Bool, ceiling: Bool = false) async throws -> String {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let repoFile = TypedRuleStore.repoFileURL(workspace: workspace)
        try FileManager.default.createDirectory(
            at: repoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        schema_version = 1
        [[rule]]
        id = "typed.git:force-push-main"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"
        branch = "main"
        """.write(to: repoFile, atomically: true, encoding: .utf8)
        if ceiling {
            let config = RVPolicyPaths.configDirectory(home: home)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try """
            schema_version = 1
            [[rule]]
            id = "typed.git:no-force-push"
            verdict = "deny"
            predicate = "gitPush"
            force = "force"
            """.write(to: RVPolicyPaths.policyCeilingFile(inConfigDir: config), atomically: true, encoding: .utf8)
        }
        let allowOnce = workspace.appendingPathComponent("allow-once", isDirectory: true)
        let probe = ThemeProbeFactory.make(
            jsonFlag: json, robotFlag: false, plainFlag: json == false, noColorFlag: true,
            stdinIsTTY: true, stdoutIsTTY: true, environment: ["TERM": "xterm"])
        let result = try await CommandRun.run(
            kind: .explain, command: "git push --force origin main", probe: probe,
            requested: .automatic, cwd: workspace.path, allowOnceDirectory: allowOnce, home: home)
        return result.stdout
    }

    /// The typed rule sits inside the tree, before Next, so the next
    /// command stays the last line.
    @Test func explain_endToEnd_showsRepoRuleBeforeNext() async throws {
        let stdout = try await explainForcePushMain(json: false, ceiling: true)
        let lines = stdout.split(separator: "\n").map(String.init)
        let rule = try #require(lines.firstIndex { $0.contains("typed.git:force-push-main") }, "\(stdout)")
        let ceiling = try #require(lines.firstIndex { $0.contains("typed.git:no-force-push") }, "\(stdout)")
        let next = try #require(lines.firstIndex { $0.contains("Next") }, "\(stdout)")
        #expect(lines[rule].contains("Your rule"))
        #expect(lines[ceiling].contains("Ceiling"))
        #expect(lines[ceiling].contains("Your rule") == false)
        #expect(rule < next && ceiling < next)
        #expect(next == lines.count - 1, "\(stdout)")
    }

    @Test func explain_json_carriesTypedRules() async throws {
        let stdout = try await explainForcePushMain(json: true)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], "\(stdout)")
        let rules = try #require(object["typed_rules"] as? [[String: String]], "\(stdout)")
        #expect(rules == [["rule_id": "typed.git:force-push-main", "source": "repo", "verdict": "deny"]])
    }
}

/// A model that drafts a non-force push for every sentence.
private struct NoForceModel: EnglishCompiler {
    func compile(_ english: String) async throws -> EnglishCompileResult {
        .preview(TypedRulePreview(
            sentence: english,
            rule: PolicyDocumentRule(
                id: RuleID(pack: .typedGit, pattern: "git-push-none-main-deny"), verdict: .deny,
                predicate: .gitPush(force: .exactly(.none), branch: "main"), english: english),
            allowedToSave: true))
    }
}
