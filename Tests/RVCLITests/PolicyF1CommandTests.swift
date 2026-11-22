import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
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
        let rules = [
            TypedRule(
                id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                predicate: .gitPush(force: .exactly(.force), branch: "main"), verdict: .deny, origin: .repo),
            TypedRule(
                id: RuleID(pack: .typedGit, pattern: "reset-hard-deny"),
                predicate: .gitReset(mode: .hard), verdict: .deny, origin: .machine),
        ]
        let push = SemanticAction.git(.push(remote: "origin", refspec: "main", force: .force))
        let packRule = RuleID(pack: .coreGit, pattern: "push-force-long")
        #expect(ExplainTypedRules.lines(rules: rules, action: push, decidedBy: packRule) == [
            "  Your rule  typed.git:force-push-main · this repo (.rv/policy.toml) · deny · also matches"
        ])
        // The rule that decided is already on the Rule line.
        #expect(ExplainTypedRules.lines(rules: rules, action: push, decidedBy: rules[0].id) == [])
        #expect(ExplainTypedRules.lines(rules: rules, action: nil, decidedBy: packRule) == [])
    }

    @Test func explain_typedAllow_saysRestrictOnly() {
        let rules = [
            TypedRule(
                id: RuleID(pack: .typedGit, pattern: "allow-main"),
                predicate: .gitPush(force: .any, branch: "main"), verdict: .allow, origin: .machine),
        ]
        let push = SemanticAction.git(.push(remote: "origin", refspec: "main", force: .force))
        let lines = ExplainTypedRules.lines(rules: rules, action: push, decidedBy: RuleID(pack: .coreGit, pattern: "x"))
        #expect(lines.count == 1)
        #expect(lines[0].contains("allow is restrict-only"))
    }

    @Test func explain_endToEnd_showsRepoRuleBesidePackDeny() async throws {
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
        let allowOnce = workspace.appendingPathComponent("allow-once", isDirectory: true)
        let probe = ThemeProbeFactory.make(
            jsonFlag: false, robotFlag: false, plainFlag: true, noColorFlag: true,
            stdinIsTTY: true, stdoutIsTTY: true, environment: ["TERM": "xterm"])
        let result = try await CommandRun.run(
            kind: .explain, command: "git push --force origin main", probe: probe,
            requested: .automatic, cwd: workspace.path, allowOnceDirectory: allowOnce, home: home)
        #expect(result.stdout.contains("typed.git:force-push-main"), "\(result.stdout)")
    }
}
