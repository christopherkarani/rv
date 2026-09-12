import Foundation
import Testing
import RVDomain
import RVPolicy

struct SafetyStoreTests {
    @Test func missingConfig_isNormal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = SafetyStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        #expect(store.loadMachine() == .normal)
        #expect(SafetyStore.loadEffective(home: home, workspace: nil) == .normal)
    }

    @Test func merge_machineStrict_cannotBeLoweredByRepoNormal() {
        #expect(SafetyStore.merge(machine: .strict, repo: .normal) == .strict)
        #expect(SafetyStore.merge(machine: .strict, repo: nil) == .strict)
    }

    @Test func merge_repoMayRaiseNormalToStrict() {
        #expect(SafetyStore.merge(machine: .normal, repo: .strict) == .strict)
        #expect(SafetyStore.merge(machine: .normal, repo: .normal) == .normal)
        #expect(SafetyStore.merge(machine: .normal, repo: nil) == .normal)
    }

    @Test func saveMachine_roundTripsAndPreservesAnalytics() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let store = SafetyStore(configDirectory: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: store.configDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{ "analytics": { "enabled": false } }"#.utf8)
            .write(to: store.configFile)
        try store.saveMachine(.strict)
        #expect(store.loadMachine() == .strict)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile))
            as? [String: Any]
        let analytics = root?["analytics"] as? [String: Any]
        #expect(analytics?["enabled"] as? Bool == false)
    }

    @Test func repoPolicy_raisesEffectiveLevel() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".rv", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("schema_version = 1\nsafety.level = \"strict\"\n".utf8).write(
            to: workspace.appendingPathComponent(".rv/policy.toml")
        )
        #expect(SafetyStore.loadEffective(home: home, workspace: workspace) == .strict)
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
