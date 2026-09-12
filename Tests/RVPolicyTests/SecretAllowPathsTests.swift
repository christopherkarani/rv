import Foundation
import Testing
import RVDomain
import RVPolicy

struct SecretAllowPathsTests {
    @Test func merge_unionsLiterals() {
        let set = SecretAllowPaths.merge(machine: [".env", "secrets"], repo: [".env", "local.env"])
        #expect(set.literals == [".env", "secrets", "local.env"])
    }

    @Test func fileDoor_literalSuppressesNonHostAuth() throws {
        let set = SecretAllowPathSet(literals: ["/tmp/rv-oracle/.env"])
        let rule = try #require(SecretPathCatalog.dayOne.firstMatch(of: "/tmp/rv-oracle/.env"))
        #expect(set.exempts("/tmp/rv-oracle/.env", rule: rule))
    }

    @Test func hostAuth_stillDeniesUnderCoveringAllowPath() throws {
        let set = SecretAllowPathSet(literals: ["~/.claude/.credentials.json", ".claude"])
        let rule = try #require(
            SecretPathCatalog.dayOne.firstMatch(of: "~/.claude/.credentials.json")
        )
        #expect(set.exempts("~/.claude/.credentials.json", rule: rule) == false)
    }

    @Test func loadEffective_readsConfigAndRepoToml() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try SecretAllowPaths.saveMachineConfig(
            ["/tmp/machine.env"],
            to: configDir.appendingPathComponent("config.json")
        )
        let workspace = URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".rv", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(
            """
            schema_version = 1
            secret.allow_paths = [".env"]
            """.utf8
        ).write(to: workspace.appendingPathComponent(".rv/policy.toml"))
        let set = SecretAllowPaths.loadEffective(home: home, workspace: workspace)
        #expect(set.literals.contains("/tmp/machine.env"))
        #expect(set.literals.contains(".env"))
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
