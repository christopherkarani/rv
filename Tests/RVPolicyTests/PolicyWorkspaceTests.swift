import Foundation
import Testing
import RVDomain
import RVPolicy

@Suite("PolicyWorkspace")
struct PolicyWorkspaceTests {
    @Test func missingFilesLoadEmptyAndDoNotMint() throws {
        let home = try isolatedHome()
        let workspace = try isolatedDirectory(prefix: "rv-pws-ws")
        defer {
            try? FileManager.default.removeItem(atPath: home.rawValue)
            try? FileManager.default.removeItem(at: workspace)
        }
        let session = PolicyWorkspace(home: home, workspace: workspace)

        #expect(try session.loadMachineDocument() == PolicyDocument())
        #expect(try session.loadRepoDocument() == PolicyDocument())
        #expect(try session.loadEffectiveRules() == [])
        let layers = try session.loadLayers()
        #expect(layers.builtin == [])
        #expect(layers.machine == [])
        #expect(layers.repo == [])
        #expect(session.documentSafetyLevel() == nil)
        #expect(session.documentAllowPaths() == .empty)

        let config = RVPolicyPaths.configDirectory(home: home)
        #expect(FileManager.default.fileExists(atPath: config.path) == false)
        #expect(
            FileManager.default.fileExists(atPath: TypedRuleStore.repoFileURL(workspace: workspace).path)
                == false
        )
    }

    @Test func tomlMachineLoadsThroughHomeSession() throws {
        let home = try isolatedHome()
        let workspace = try isolatedDirectory(prefix: "rv-pws-ws")
        defer {
            try? FileManager.default.removeItem(atPath: home.rawValue)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        let rule = forcePushMainDeny(origin: .machine)
        try store.saveMachine([rule])

        let session = PolicyWorkspace(home: home, workspace: workspace)
        let document = try session.loadMachineDocument()
        #expect(document.typedRules(origin: .machine) == [rule])
        #expect(try session.loadEffectiveRules() == [rule])
        #expect(try session.loadLayers().machine == [rule])
        #expect(
            FileManager.default.fileExists(atPath: store.machineLegacyJSONURL.path) == false
        )
    }

    @Test func repoOverlayMatchesTypedRuleStoreMerge() throws {
        let home = try isolatedHome()
        let workspace = try isolatedDirectory(prefix: "rv-pws-ws")
        defer {
            try? FileManager.default.removeItem(atPath: home.rawValue)
            try? FileManager.default.removeItem(at: workspace)
        }
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        let machineDeny = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: predicate,
            verdict: .deny,
            origin: .machine
        )
        let repoAllow = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main-allow"),
            predicate: predicate,
            verdict: .allow,
            origin: .repo
        )
        let store = TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        try store.saveMachine([machineDeny])
        try store.saveRepo([repoAllow], workspace: workspace)

        let session = PolicyWorkspace(home: home, workspace: workspace)
        let effective = try session.loadEffectiveRules()
        let oracle = try store.loadEffective(builtin: [], workspace: workspace)
        #expect(effective == oracle)
        #expect(
            effective == TypedRuleStore.merge(
                builtin: [],
                machine: [machineDeny],
                repo: [repoAllow]
            )
        )
        #expect(effective == [machineDeny])
        #expect(try session.loadLayers().repo == [repoAllow])
    }

    @Test func nilHomeLoadsRepoOnlyLikeGatedEvaluate() throws {
        let workspace = try isolatedDirectory(prefix: "rv-pws-ws")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let repo = forcePushMainDeny(origin: .repo)
        try TypedRuleStore(baseDirectory: workspace).saveRepo([repo], workspace: workspace)

        let session = PolicyWorkspace(home: nil, workspace: workspace)
        #expect(try session.loadMachineDocument() == PolicyDocument())
        #expect(try session.loadRepoDocument().typedRules(origin: .repo) == [repo])
        #expect(
            try session.loadEffectiveRules()
                == TypedRuleStore.merge(builtin: [], machine: [], repo: [repo])
        )
        #expect(try session.loadEffectiveRules() == [repo])
    }

    @Test func configDirectoryInitPersistsMachineWithoutHome() throws {
        let config = try isolatedDirectory(prefix: "rv-pws-config")
        defer { try? FileManager.default.removeItem(at: config) }
        let session = PolicyWorkspace(configDirectory: config)
        let rule = PolicyDocumentRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            verdict: .deny,
            predicate: .gitPush(force: .exactly(.force), branch: "main")
        )

        try session.upsert(rule, layer: .machine)

        let loaded = try session.loadMachineDocument()
        #expect(loaded.rules == [rule])
        #expect(try session.loadEffectiveRules() == [rule.typedRule(origin: .machine)])
        #expect(
            FileManager.default.fileExists(
                atPath: RVPolicyPaths.policyFile(inConfigDir: config).path
            )
        )
        #expect(session.home == nil)
    }

    @Test func upsertUsesMergeLayerSemantics() throws {
        let home = try isolatedHome()
        let workspace = try isolatedDirectory(prefix: "rv-pws-ws")
        defer {
            try? FileManager.default.removeItem(atPath: home.rawValue)
            try? FileManager.default.removeItem(at: workspace)
        }
        let session = PolicyWorkspace(home: home, workspace: workspace)
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        let allow = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "allow"),
            verdict: .allow,
            predicate: predicate
        )
        let deny = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "deny"),
            verdict: .deny,
            predicate: predicate,
            english: "Never allow force-push to main"
        )

        try session.upsert(allow, layer: .machine)
        try session.upsert(deny, layer: .machine)
        #expect(try session.loadMachineDocument().rules == [deny])

        try session.upsert(allow, layer: .machine)
        #expect(try session.loadMachineDocument().rules == [deny])

        let other = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "discard"),
            verdict: .ask,
            predicate: .gitDiscardWorktree(pathspec: nil)
        )
        try session.upsert(other, layer: .repo)
        let repo = try session.loadRepoDocument()
        #expect(repo.rules == [other])
        #expect(try session.loadMachineDocument().safetyLevel == nil)
    }

    @Test func mergeIncomingPreviewDoesNotWrite() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let session = PolicyWorkspace(home: home)
        let existing = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "allow"),
            verdict: .allow,
            predicate: .gitPush(force: .exactly(.force), branch: "main")
        )
        try session.upsert(existing, layer: .machine)
        let incoming = PolicyDocument(
            rules: [
                PolicyDocumentRule(
                    id: RuleID(pack: .typedGit, pattern: "deny"),
                    verdict: .deny,
                    predicate: .gitPush(force: .exactly(.force), branch: "main")
                ),
            ]
        )

        let preview = try session.mergeIncoming(incoming, layer: .machine, save: false)
        #expect(preview.rules == incoming.rules)
        #expect(try session.loadMachineDocument().rules == [existing])

        let saved = try session.mergeIncoming(incoming, layer: .machine, save: true)
        #expect(saved.rules == incoming.rules)
        #expect(try session.loadMachineDocument().rules == incoming.rules)
    }

    @Test func documentFieldsIgnoreConfigJSON() throws {
        let home = try isolatedHome()
        let workspace = try isolatedDirectory(prefix: "rv-pws-ws")
        defer {
            try? FileManager.default.removeItem(atPath: home.rawValue)
            try? FileManager.default.removeItem(at: workspace)
        }
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try SecretAllowPaths.saveMachineConfig(
            ["/tmp/from-config.env"],
            to: config.appendingPathComponent("config.json")
        )
        try SafetyStore(configDirectory: config).saveMachine(.strict)

        let empty = PolicyWorkspace(home: home, workspace: workspace)
        #expect(empty.documentSafetyLevel() == nil)
        #expect(empty.documentAllowPaths() == .empty)

        let store = TypedRuleStore(baseDirectory: config)
        try store.saveMachine(
            PolicyDocument(safetyLevel: .normal, allowPaths: [".env"])
        )
        try store.saveRepo(
            PolicyDocument(safetyLevel: .strict, allowPaths: ["secrets"]),
            workspace: workspace
        )
        let session = PolicyWorkspace(home: home, workspace: workspace)
        #expect(session.documentSafetyLevel() == .strict)
        #expect(session.documentAllowPaths().literals == [".env", "secrets"])
        #expect(session.documentAllowPaths().literals.contains("/tmp/from-config.env") == false)
    }

    @Test func writeWithoutLayerThrows() {
        let session = PolicyWorkspace(home: nil, workspace: nil)
        let rule = PolicyDocumentRule(
            id: RuleID(pack: .typedGit, pattern: "deny"),
            verdict: .deny,
            predicate: .gitPush(force: .exactly(.force), branch: "main")
        )
        #expect(throws: PolicyWorkspaceError.missingLayer(.machine)) {
            try session.upsert(rule, layer: .machine)
        }
        #expect(throws: PolicyWorkspaceError.missingLayer(.repo)) {
            try session.upsert(rule, layer: .repo)
        }
    }

    @Test func invalidMachineTOMLFailsClosed() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: store.machineFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not-toml".write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        let session = PolicyWorkspace(home: home)
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try session.loadEffectiveRules()
        }
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try session.loadLayers()
        }
        #expect(session.documentSafetyLevel() == nil)
    }
}

private func forcePushMainDeny(origin: TypedRuleOrigin) -> TypedRule {
    TypedRule(
        id: RuleID(pack: .coreGit, pattern: "force-push-main"),
        predicate: .gitPush(force: .exactly(.force), branch: "main"),
        verdict: .deny,
        origin: origin
    )
}

private func isolatedHome() throws -> HomeDirectory {
    let url = try isolatedDirectory(prefix: "rv-pws-home")
    return try #require(HomeDirectory(validating: url.path))
}

private func isolatedDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
