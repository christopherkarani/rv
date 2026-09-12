import Foundation
import Testing
import RVDomain
import RVPolicy

/// Garbage safety / allow_paths overlay degrades. Invalid machine `policy.toml`
/// still fail-closes at `GatedEvaluateTypedRuleLoadTests`.
struct OptionalOverlayDegradeTests {
    @Test func invalidConfigSafetyLevel_isNormal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = SafetyStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: store.configDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{ "safety": { "level": "paranoid" } }"#.utf8).write(to: store.configFile)
        #expect(store.loadMachine() == .normal)
        #expect(SafetyStore.loadEffective(home: home, workspace: nil) == .normal)
    }

    @Test(arguments: [
        "schema_version = 1\nsafety.level = \"paranoid\"\n",
        "schema_version = 1\nsafety.level = \"str",
        "not-toml\n",
    ])
    func invalidRepoSafetyOverlay_effectiveStaysNormal(toml: String) throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try writeRepoPolicy(home: home, toml: toml)
        #expect(SafetyStore.loadEffective(home: home, workspace: workspace) == .normal)
    }

    @Test func unreadableRepoPolicy_effectiveStaysNormal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try writeRepoPolicy(
            home: home,
            toml: "schema_version = 1\nsafety.level = \"strict\"\n"
        )
        let policy = TypedRuleStore.repoFileURL(workspace: workspace)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: policy.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: policy.path
            )
        }
        #expect(SafetyStore.loadEffective(home: home, workspace: workspace) == .normal)
    }

    @Test func garbageRepoOverlay_doesNotLowerMachineStrict() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = SafetyStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: store.configDirectory,
            withIntermediateDirectories: true
        )
        try store.saveMachine(.strict)
        let workspace = try writeRepoPolicy(home: home, toml: "not-toml\n")
        #expect(SafetyStore.loadEffective(home: home, workspace: workspace) == .strict)
    }

    @Test func brokenConfigAllowPaths_returnsUsableSet() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(#"{ "secret": { "allow_paths": "not-an-array" } }"#.utf8)
            .write(to: configDir.appendingPathComponent("config.json"))
        let set = SecretAllowPaths.loadEffective(home: home, workspace: nil)
        #expect(set == .empty)
    }

    @Test(arguments: [
        "schema_version = 1\nsecret.allow_paths = [\".env\"\n",
        "schema_version = 1\nsecret.allow_paths = \"nope\"\n",
        "not-toml\n",
    ])
    func brokenRepoAllowPaths_returnsUsableSet(toml: String) throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try writeRepoPolicy(home: home, toml: toml)
        let set = SecretAllowPaths.loadEffective(home: home, workspace: workspace)
        #expect(set == .empty)
    }

    @Test func brokenRepoAllowPaths_keepsMachineLiterals() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try SecretAllowPaths.saveMachineConfig(
            ["/tmp/machine.env"],
            to: configDir.appendingPathComponent("config.json")
        )
        let workspace = try writeRepoPolicy(
            home: home,
            toml: "schema_version = 1\nsecret.allow_paths = [\".env\"\n"
        )
        let set = SecretAllowPaths.loadEffective(home: home, workspace: workspace)
        #expect(set.literals == ["/tmp/machine.env"])
    }

    private func writeRepoPolicy(home: HomeDirectory, toml: String) throws -> URL {
        let workspace = URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".rv", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(toml.utf8).write(to: workspace.appendingPathComponent(".rv/policy.toml"))
        return workspace
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-overlay-degrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
