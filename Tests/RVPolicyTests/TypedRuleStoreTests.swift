import Foundation
import Testing
import RVDomain
import RVPolicy

@Suite("TypedRuleStore")
struct TypedRuleStoreTests {
    @Test func roundTripsGitPushDenyInTempDirectory() throws {
        let root = try isolatedTypedRuleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: .gitPush(force: .force, branch: "main"),
            verdict: .deny,
            origin: .machine
        )

        try store.saveMachine([rule])
        let loaded = try store.loadMachine()

        #expect(loaded == [rule])
    }

    @Test func repoAllowCannotDropMachineDeny() {
        let predicate = PolicyPredicate.gitPush(force: .force, branch: "main")
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

        let merged = TypedRuleStore.merge(
            builtin: [],
            machine: [machineDeny],
            repo: [repoAllow]
        )

        #expect(merged == [machineDeny])
    }

    @Test func machineAllowCannotDropBuiltinDeny() {
        let predicate = PolicyPredicate.gitPush(force: .force, branch: "main")
        let builtinDeny = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main-builtin"),
            predicate: predicate,
            verdict: .deny,
            origin: .builtin
        )
        let machineAllow = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: predicate,
            verdict: .allow,
            origin: .machine
        )

        let merged = TypedRuleStore.merge(
            builtin: [builtinDeny],
            machine: [machineAllow],
            repo: []
        )

        #expect(merged == [builtinDeny])
    }

    @Test func repoAllowCannotDropMachineDenyFromDisk() throws {
        let config = try isolatedTypedRuleDirectory()
        let workspace = try isolatedTypedRuleDirectory()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = TypedRuleStore(baseDirectory: config)
        let predicate = PolicyPredicate.gitPush(force: .force, branch: "main")
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

        try store.saveMachine([machineDeny])
        try store.saveRepo([repoAllow], workspace: workspace)
        let merged = try store.loadEffective(builtin: [], workspace: workspace)

        #expect(merged == [machineDeny])
        #expect(try store.loadRepo(workspace: workspace) == [repoAllow])
    }

    @Test func onDiskJSONOmitsRawArgv() throws {
        let root = try isolatedTypedRuleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: .gitPush(force: .force, branch: "main"),
            verdict: .deny,
            origin: .machine
        )

        try store.saveMachine([rule])
        let json = try String(contentsOf: store.machineFileURL, encoding: .utf8)

        #expect(json.contains("supportingCommand") == false)
        #expect(json.contains("argv") == false)
        #expect(json.contains("git push") == false)
        #expect(json.contains("--force") == false)
        #expect(json.contains("english") == false)
        #expect(json.contains("\"schemaVersion\":1"))
        #expect(json.contains("\"branch\":\"main\""))
        #expect(json.contains("\"gitPush\""))
    }

    @Test func missingMachineFileLoadsEmpty() throws {
        let root = try isolatedTypedRuleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        #expect(try store.loadMachine() == [])
    }

    @Test func invalidMachineFileFailsClosed() throws {
        let root = try isolatedTypedRuleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        try "not-json".write(to: store.machineFileURL, atomically: true, encoding: .utf8)
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.loadMachine()
        }
    }

    @Test func machineFileUsesPolicyPaths() throws {
        let root = try isolatedTypedRuleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        #expect(store.machineFileURL == RVPolicyPaths.typedRulesFile(inConfigDir: root))
    }

    @Test func schemaVersionRoundTripsAndRejectsOtherVersions() throws {
        let root = try isolatedTypedRuleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TypedRuleStore(baseDirectory: root)
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: .gitPush(force: .force, branch: "main"),
            verdict: .deny,
            origin: .machine
        )

        try store.saveMachine([rule])
        let json = try String(contentsOf: store.machineFileURL, encoding: .utf8)
        #expect(json.contains("\"schemaVersion\":1"))
        #expect(try store.loadMachine() == [rule])

        try #"{"schemaVersion":2,"rules":[]}"#.write(
            to: store.machineFileURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.loadMachine()
        }

        try #"{"rules":[]}"#.write(
            to: store.machineFileURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: TypedRuleStoreError.invalidFile) {
            _ = try store.loadMachine()
        }
    }
}

private func isolatedTypedRuleDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-typed-rules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
