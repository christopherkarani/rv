import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

@Suite("PolicyDraftCommand")
struct PolicyDraftCommandTests {
    @Test func helpListsPolicyDraft() {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("policy"))
        #expect(PolicyDraftCommand.configuration.commandName == "draft")
        let children = Policy.configuration.subcommands.map { $0.configuration.commandName }
        #expect(children.contains("show"))
        #expect(children.contains("draft"))
        #expect(Policy.helpMessage().contains("draft"))
        #expect(RV.helpMessage().contains("policy"))
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
            #expect(result.text.contains("Always block force-push to main."))
            #expect(result.text.contains("gitPush"))
            #expect(result.text.contains("force=force"))
            #expect(result.text.contains("branch=main"))
            #expect(result.text.contains("deny"))
            #expect(result.text.contains("never allow") == false)
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
            #expect(result.text.contains("_0") == false)
            #expect(result.text.contains("english") == false)
            #expect(result.text.contains("never allow") == false)

            let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8))
            let dictionary = try #require(object as? [String: Any])
            #expect(dictionary["allowedToSave"] as? Bool == true)
            #expect(dictionary["english"] == nil)
            let draft = try #require(dictionary["draft"] as? [String: Any])
            #expect(draft["verdict"] as? String == "deny")
            #expect(draft["origin"] as? String == "machine")
            let predicate = try #require(draft["predicate"] as? [String: Any])
            let gitPush = try #require(predicate["gitPush"] as? [String: Any])
            #expect(gitPush["force"] as? String == "force")
            #expect(gitPush["branch"] as? String == "main")
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
    }

    @Test func save_persistsMachineDeny() async throws {
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
            #expect(machine[0].id == RuleID(pack: .coreGit, pattern: "force-push-main"))

            let encoded = try JSONEncoder().encode(machine[0])
            let json = String(decoding: encoded, as: UTF8.self)
            #expect(json.contains("english") == false)
            #expect(json.contains("never allow") == false)

            let snapshot = try PolicyShowRun.load(home: home, workspace: workspace)
            #expect(snapshot.machine == machine)
            #expect(snapshot.repo.isEmpty)
            #expect(
                FileManager.default.fileExists(
                    atPath: TypedRuleStore.repoFileURL(workspace: workspace).path
                ) == false
            )
        }
    }

    @Test func save_upsertsSamePredicate_keepsOtherMachineRules() async throws {
        try await withTempPolicyContext { home, workspace in
            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            let other = TypedRule(
                id: RuleID(pack: .coreGit, pattern: "force-push-develop"),
                predicate: .gitPush(force: .force, branch: "develop"),
                verdict: .deny,
                origin: .machine
            )
            try store.saveMachine([other])

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
                machine.filter { $0.predicate == .gitPush(force: .force, branch: "main") }.count == 1
            )
        }
    }

    @Test func refuse_writesNothing() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "be careful in prod",
                save: false,
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

    @Test func refuse_withSave_writesNothing() async throws {
        try await withTempPolicyContext { home, workspace in
            let result = try await PolicyDraftRun.execute(
                english: "be careful in prod",
                save: true,
                robot: true,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
            #expect(result.outcome == .refuse(.uncompilable))
            let decoded = try JSONDecoder().decode(
                PolicyDraftRobotRefuse.self,
                from: Data(result.text.utf8)
            )
            #expect(decoded == PolicyDraftRobotRefuse(refuse: .uncompilable))
            #expect(result.text.contains("_0") == false)
            assertNoPolicyWrites(home: home, workspace: workspace)
        }
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
    #expect(
        FileManager.default.fileExists(
            atPath: RVPolicyPaths.allowOnceFile(inConfigDir: config).path
        ) == false
    )
    #expect(
        FileManager.default.fileExists(
            atPath: RVPolicyPaths.allowlistFile(inConfigDir: config).path
        ) == false
    )
}
