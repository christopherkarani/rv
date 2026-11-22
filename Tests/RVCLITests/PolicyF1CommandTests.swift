import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
import RVPresentation
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
        #expect(out.stdout == "Always block force-push to main\ntyped.git:force-push-main deny gitPush force=force branch=main\n")
    }

    @Test func draft_sentenceGivenTwice_isAUsageError() {
        #expect(throws: (any Error).self) {
            try PolicyDraftCommand.parseAsRoot(["never push", "--english", "never push"])
        }
    }

    @Test func draft_refusal_isOneLineWithTheReason() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        let result = try await PolicyDraftRun.execute(
            english: "never npm publish", save: false, robot: false, home: home, workspace: workspace,
            compiler: PlainEnglishRuleCompiler())
        #expect(result.outcome == .refuse(.unsupportedPredicate))
        #expect(result.text == "refused (unsupportedPredicate): a rule can't cover npm yet; drafts cover git push, "
            + "reset, clean and restore, and deleting or moving files")
        #expect(result.text.contains("\n") == false)
    }

    @Test func draft_modelRefusalStillGetsAReason() async throws {
        let (home, workspace) = try scratch()
        defer { cleanup(home, workspace) }
        // A compiler that only says "uncompilable" for a sentence the grammar reads
        // as a vague one still prints the grammar's reason.
        let result = try await PolicyDraftRun.execute(
            english: "be careful in prod", save: false, robot: false, home: home, workspace: workspace,
            compiler: FakeEnglishCompiler())
        #expect(result.text.hasPrefix("refused (uncompilable): start with never, ask before, or allow"))
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
        #expect(result.text.hasSuffix("\n" + PolicyDraftRun.restrictOnlyNote))
        #expect(PolicyDraftRun.restrictOnlyNote.contains("restrict-only"))
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
