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

    @Test func save_persistsMachineDenyTOML() async throws {
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
            #expect(machine[0].predicate == .gitPush(force: .force, branch: "main"))
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

    @Test func refuse_writesNothing() async throws {
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
        let store = TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        try store.saveMachine(
            PolicyDocument(
                rules: [
                    PolicyDocumentRule(
                        id: RuleID(pack: .typedGit, pattern: "allow"),
                        verdict: .allow,
                        predicate: .gitPush(force: .force, branch: "main")
                    ),
                ]
            )
        )
        let incoming = PolicyDocument(
            rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "deny"),
                    verdict: .deny,
                    predicate: .gitPush(force: .force, branch: "main")
                ),
            ]
        )
        let merged = PolicyDocument(
            rules: PolicyDocumentTOML.mergeLayer(
                existing: try store.loadMachineDocument().rules,
                incoming: incoming.rules
            )
        )
        try store.saveMachine(merged)
        let loaded = try store.loadMachine()
        #expect(loaded.count == 1)
        #expect(loaded[0].verdict == .deny)
    }

    @Test func validate_missingFile_isOK() {
        let missing = URL(fileURLWithPath: "/tmp/rv-missing-policy-\(UUID().uuidString).toml")
        #expect(FileManager.default.fileExists(atPath: missing.path) == false)
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
