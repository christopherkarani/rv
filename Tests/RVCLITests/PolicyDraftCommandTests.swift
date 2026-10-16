import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

struct PolicyDraftCommandTests {
    @Test func helpListsPolicyDraft() {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("policy"))
        #expect(PolicyDraftCommand.configuration.commandName == "draft")
        let children = Policy.configuration.subcommands.map { $0.configuration.commandName }
        #expect(children.contains("show"))
        #expect(children.contains("draft"))
        #expect(Policy.helpMessage().contains("draft"))
    }

    @Test func draftEnglish_printsPreview_writesNothing() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "never allow force-push to main",
                save: false,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
            #expect(result.outcome == .preview(saved: false))
            #expect(result.text.contains("Always block force-push to main"))
            #expect(result.text.contains("gitPush"))
            #expect(result.text.contains("force=force"))
            #expect(result.text.contains("branch=main"))
            #expect(result.text.contains("deny"))
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
    }

    @Test func robotEscapesEnglishSeparators() async throws {
        try await withTempPolicyContext { home, workspace in
            let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
            let english = "x\u{1B}" + sentence + "\u{2028}" + sentence + "\u{2029}" + sentence + "\u{202E}" + sentence
            let result = try await PolicyDraftRun.execute(
                english: english,
                save: false,
                robot: true,
                home: home,
                workspace: workspace,
                compiler: PreviewEnglishCompiler()
            )
            #expect(result.outcome == .preview(saved: false))
            #expect(result.text.unicodeScalars.contains { $0.value == 0x1B } == false)
            #expect(result.text.unicodeScalars.contains { $0.value == 0x2028 } == false)
            #expect(result.text.unicodeScalars.contains { $0.value == 0x2029 } == false)
            #expect(result.text.unicodeScalars.contains { $0.value == 0x202E } == false)
            #expect(result.text.contains("\\u001b"))
            #expect(result.text.contains("\\u2028"))
            #expect(result.text.contains("\\u2029"))
            #expect(result.text.contains("\\u202e"))
            #expect(result.text.contains("\"english\""))
            let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8))
            let dictionary = try #require(object as? [String: Any])
            let rule = try #require(dictionary["rule"] as? [String: Any])
            #expect(rule["english"] as? String != nil)
            let split = result.text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
            #expect(split.contains(sentence) == false)
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
    }

    @Test func draftEnglish_robotJSON_includesGitPushAndAllowedToSave() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "never allow force-push to main",
                save: false,
                robot: true,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
            #expect(result.outcome == .preview(saved: false))
            #expect(result.text.contains("gitPush"))
            #expect(result.text.contains("allowedToSave"))
            #expect(result.text.contains("\"force\":\"force\""))
            #expect(result.text.contains("\"branch\":\"main\""))

            let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8))
            let dictionary = try #require(object as? [String: Any])
            #expect(dictionary["allowedToSave"] as? Bool == true)
            let rule = try #require(dictionary["rule"] as? [String: Any])
            #expect(rule["verdict"] as? String == "deny")
            let predicate = try #require(rule["predicate"] as? [String: Any])
            let gitPush = try #require(predicate["gitPush"] as? [String: Any])
            #expect(gitPush["force"] as? String == "force")
            #expect(gitPush["branch"] as? String == "main")
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func save_persistsMachineDenyTOML() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "never allow force-push to main",
                save: true,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
            #expect(result.outcome == .preview(saved: true))

            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            let machine = try store.loadMachine()
            #expect(machine.count == 1)
            #expect(machine[0].predicate == .gitPush(force: .exactly(.force), branch: "main"))
            #expect(machine[0].verdict == .deny)
            #expect(machine[0].origin == .machine)
            #expect(machine[0].id == RuleID(pack: .typedGit, pattern: "force-push-main"))

            let toml = try String(contentsOf: store.machineFileURL, encoding: .utf8)
            #expect(toml.contains("predicate = \"gitPush\""))
            #expect(toml.contains("Never allow force-push to main") || toml.contains("never allow force-push to main"))
            #expect(
                FileManager.default.fileExists(atPath: store.machineLegacyJSONURL.path) == false
            )
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func save_upsertsSamePredicate_keepsOtherMachineRules() async throws {
        try await withTempPolicyContext { home, workspace in
            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            let other = PolicyDocumentRule(
                id: RuleID(pack: .typedGit, pattern: "force-push-develop"),
                verdict: .deny,
                predicate: .gitPush(force: .exactly(.force), branch: "develop")
            )
            try store.saveMachine(PolicyDocument(rules: [other]))

            let first = try await PolicyDraftRun.execute(
                english: "never allow force-push to main",
                save: true,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
            #expect(first.outcome == .preview(saved: true))
            let second = try await PolicyDraftRun.execute(
                english: "never force-push main",
                save: true,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
            #expect(second.outcome == .preview(saved: true))

            let machine = try store.loadMachine()
            #expect(machine.count == 2)
            #expect(machine.contains(where: { $0.predicate == other.predicate && $0.verdict == .deny }))
            #expect(
                machine.filter { $0.predicate == .gitPush(force: .exactly(.force), branch: "main") }.count == 1
            )
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func refuse_writesNothing() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "be careful in prod",
                save: true,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
            #expect(result.outcome == .refuse(.uncompilable))
            #expect(result.text.contains("uncompilable"))
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
    }

    @Test func run_constructsChainAndCallsExecuteOnce() throws {
        let source = try String(contentsOf: policyDraftCommandSourceURL(), encoding: .utf8)
        let run = try #require(source.split(separator: "func run() async throws", maxSplits: 1).last)
        let body = String(run.split(separator: "struct PolicyDraftResult", maxSplits: 1)[0])
        #expect(body.contains("EnglishCompileChain("))
        #expect(body.components(separatedBy: "PolicyDraftRun.execute").count == 2)
        #expect(body.contains("catch is EnglishCompilerError") == false)
        #expect(body.contains("FakeEnglishCompiler(") == false)
        #expect(source.contains("TypedRuleStore(") == false)
        #expect(source.contains("mergeLayer") == false)
        #expect(source.contains("PolicyWorkspace("))
        #expect(source.contains(".upsert("))
    }

    @Test func unavailablePrimary_fixtureEnglish_previewsCannedGitPushDeny() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "never allow force-push to main",
                save: false,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: EnglishCompileChain(
                    primary: UnavailableEnglishCompiler(),
                    fallback: FakeEnglishCompiler()
                )
            )
            #expect(result.outcome == .preview(saved: false))
            #expect(result.text.contains("Always block force-push to main"))
            #expect(result.text.contains("gitPush"))
            #expect(result.text.contains("force=force"))
            #expect(result.text.contains("branch=main"))
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func unavailablePrimary_uncompilableEnglish_refusesAndWritesNothing() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "be careful in prod",
                save: true,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: EnglishCompileChain(
                    primary: UnavailableEnglishCompiler(),
                    fallback: FakeEnglishCompiler()
                )
            )
            #expect(result.outcome == .refuse(.uncompilable))
            #expect(result.text.contains("uncompilable"))
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func save_unavailablePrimary_persistsFakePreviewOnce() async throws {
        try await withTempPolicyContext { home, workspace in
            let fallbackLog = CompileCallLog()
            let result = try await PolicyDraftRun.execute(
                english: "never allow force-push to main",
                save: true,
                robot: false,
                home: home,
                workspace: workspace,
                compiler: EnglishCompileChain(
                    primary: UnavailableEnglishCompiler(),
                    fallback: CountingEnglishCompiler(log: fallbackLog)
                )
            )
            #expect(result.outcome == .preview(saved: true))
            #expect(await fallbackLog.count == 1)

            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            let machine = try store.loadMachine()
            #expect(machine.count == 1)
            #expect(machine[0].predicate == .gitPush(force: .exactly(.force), branch: "main"))
            #expect(machine[0].verdict == .deny)
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func save_storeError_doesNotInvokeFallbackAgain() async throws {
        try await withTempPolicyContext { home, workspace in
            let config = RVPolicyPaths.configDirectory(home: home)
            try FileManager.default.createDirectory(
                at: config.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: config)

            let fallbackLog = CompileCallLog()
            var threw = false
            do {
                let result = try await PolicyDraftRun.execute(
                    english: "never allow force-push to main",
                    save: true,
                    robot: false,
                    home: home,
                    workspace: workspace,
                    compiler: EnglishCompileChain(
                        primary: UnavailableEnglishCompiler(),
                        fallback: CountingEnglishCompiler(log: fallbackLog)
                    )
                )
                Issue.record("expected store failure, got \(result.outcome)")
            } catch {
                threw = true
            }
            #expect(threw)
            #expect(await fallbackLog.count == 1)
            #expect(
                FileManager.default.fileExists(
                    atPath: TypedRuleStore(baseDirectory: config).machineFileURL.path
                ) == false
            )
        }
    }
}

struct PolicyDocumentCommandTests {
    @Test func apply_englishOnly_refuses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-policy-english-only-\(UUID().uuidString).toml")
        try """
        schema_version = 1
        [[rule]]
        id = "typed.git:x"
        verdict = "deny"
        english = "Never force-push main"
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PolicyDocumentError.invalidFile) {
            _ = try PolicyDocumentRun.load(url)
        }
    }

    @Test func apply_save_keepsTighterDeny() throws {
        let home = try isolatedHome()
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let session = PolicyWorkspace(home: home)
        try session.upsert(
            PolicyDocumentRule(
                id: RuleID(pack: .typedGit, pattern: "allow"),
                verdict: .allow,
                predicate: .gitPush(force: .exactly(.force), branch: "main")
            ),
            layer: .machine
        )
        let incoming = PolicyDocument(
            rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "deny"),
                    verdict: .deny,
                    predicate: .gitPush(force: .exactly(.force), branch: "main")
                ),
            ]
        )
        let merged = try session.mergeIncoming(incoming, layer: .machine, save: true)
        #expect(merged.rules.count == 1)
        #expect(merged.rules[0].verdict == .deny)
        let loaded = try session.loadMachineDocument()
        #expect(loaded.rules.count == 1)
        #expect(loaded.rules[0].verdict == .deny)
    }

    @Test func validate_missingFile_isOK() throws {
        let home = try isolatedHome()
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let missing = URL(fileURLWithPath: "/tmp/rv-missing-policy-\(UUID().uuidString).toml")
        #expect(FileManager.default.fileExists(atPath: missing.path) == false)
        try PolicyValidateRun.validate(.file(missing, home))
    }

    @Test func validate_defaultPath_invalidLegacyJSON_failsClosed() throws {
        let home = try isolatedHome()
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "not-json".write(
            to: RVPolicyPaths.typedRulesFile(inConfigDir: config),
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: TypedRuleStoreError.invalidFile) {
            try PolicyValidateRun.validate(.machine(home))
        }
    }

    @Test func validate_defaultPath_invalidTOML_failsClosed() throws {
        let home = try isolatedHome()
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "not-toml".write(
            to: RVPolicyPaths.policyFile(inConfigDir: config),
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: TypedRuleStoreError.invalidFile) {
            try PolicyValidateRun.validate(.machine(home))
        }
    }

    @Test func validate_shareAskingRelaxation_blocks() throws {
        let home = try isolatedHome()
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let store = TypedRuleStore(
            baseDirectory: RVPolicyPaths.configDirectory(home: home)
        )
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        try store.saveMachine(
            PolicyDocument(
                rules: [
                    PolicyDocumentRule(
                        id: RuleID(pack: .coreGit, pattern: "force-push-main"),
                        verdict: .deny,
                        predicate: predicate
                    )
                ]
            )
        )
        let share = homeURL.appendingPathComponent("share.toml")
        try PolicyDocumentTOML.render(
            PolicyDocument(
                rules: [
                    PolicyDocumentRule(
                        id: RuleID(pack: .typedGit, pattern: "share-allow"),
                        verdict: .allow,
                        predicate: predicate
                    )
                ]
            )
        ).write(to: share, atomically: true, encoding: .utf8)

        let report = try PolicyValidateRun.riskReport(.file(share, home))
        #expect(report.hasBlockingFindings)
        #expect(
            report.findings == [
                PolicyDiffRiskFinding(
                    kind: .verdictRelaxed,
                    severity: .blocking,
                    detail: "typed.git:share-allow deny->allow"
                )
            ]
        )
        #expect(throws: PolicyDiffRiskError.blockedByFindings(report)) {
            try PolicyValidateRun.validate(.file(share, home))
        }
    }

    @Test func validate_partialShareOmittingMachineRules_isClean() throws {
        let home = try isolatedHome()
        let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let store = TypedRuleStore(
            baseDirectory: RVPolicyPaths.configDirectory(home: home)
        )
        try store.saveMachine(
            PolicyDocument(
                rules: [
                    PolicyDocumentRule(
                        id: RuleID(pack: .coreGit, pattern: "force-push-main"),
                        verdict: .deny,
                        predicate: .gitPush(force: .exactly(.force), branch: "main")
                    )
                ]
            )
        )
        // A share that never mentions the machine deny omits it; the merge
        // preserves it, so validation must not read a removal.
        let share = homeURL.appendingPathComponent("share.toml")
        try PolicyDocumentTOML.render(
            PolicyDocument(
                rules: [
                    PolicyDocumentRule(
                        id: RuleID(pack: .typedGit, pattern: "tighten"),
                        verdict: .deny,
                        predicate: .gitDiscardWorktree(pathspec: nil)
                    )
                ]
            )
        ).write(to: share, atomically: true, encoding: .utf8)

        let report = try PolicyValidateRun.riskReport(.file(share, home))
        #expect(report.findings.isEmpty)
        try PolicyValidateRun.validate(.file(share, home))
    }
}

private func withTempPolicyContext(
    _ body: (HomeDirectory, URL) async throws -> Void
) async throws {
    let home = try isolatedHome()
    let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-policy-draft-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: workspace)
    }
    try await body(home, workspace)
}

private func policyDraftCommandSourceURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RVCLI/Commands/PolicyDraftCommand.swift")
}

private struct PreviewEnglishCompiler: EnglishCompiler {
    func compile(_ english: String) async throws -> EnglishCompileResult {
        .preview(
            TypedRulePreview(
                sentence: "Always block force-push to main",
                rule: PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "force-push-main"),
                    verdict: .deny,
                    predicate: .gitPush(force: .exactly(.force), branch: "main"),
                    english: english
                ),
                allowedToSave: true
            )
        )
    }
}

private struct UnavailableEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        throw EnglishCompilerError.unavailable
    }
}

private actor CompileCallLog {
    private(set) var count = 0
    func mark() { count += 1 }
}

private struct CountingEnglishCompiler: EnglishCompiler {
    let log: CompileCallLog
    let inner = FakeEnglishCompiler()

    func compile(_ english: String) async throws -> EnglishCompileResult {
        await log.mark()
        return try await inner.compile(english)
    }
}

private func assertNoPolicyWrites(home: HomeDirectory, workspace: URL) {
    let config = RVPolicyPaths.configDirectory(home: home)
    #expect(FileManager.default.fileExists(atPath: config.path) == false)
    #expect(
        FileManager.default.fileExists(
            atPath: TypedRuleStore(baseDirectory: config).machineFileURL.path
        ) == false
    )
    #expect(
        FileManager.default.fileExists(
            atPath: TypedRuleStore.repoFileURL(workspace: workspace).path
        ) == false
    )
}
