import Foundation
import Testing
import RVDomain
import RVPolicy

struct SecretAllowPathsTests {
    @Test func merge_unionsLiterals() {
        let set = SecretAllowPaths.merge(machine: [".env", "secrets"], repo: [".env", "local.env"])
        #expect(set.literals == [".env", "secrets", "local.env"])
    }

    @Test func merge_blessedUnionKeepsOnlyBlessedRepo() {
        let result = SecretAllowPaths.merge(
            machine: ["a", "b"],
            repo: ["b", "c", "d", "c", "  "],
            blessPaths: ["c", "zzz"]
        )
        #expect(result.effective.literals == ["a", "b", "c"])
        #expect(result.droppedRepoLiterals == ["d"])
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
        try SecretAllowPaths.saveBlessPaths(
            [".env"],
            to: configDir.appendingPathComponent("config.json")
        )
        try TypedRuleStore(baseDirectory: configDir).saveMachine(
            PolicyDocument(allowPaths: ["/tmp/machine-doc.env"])
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
        #expect(set.literals == ["/tmp/machine.env", "/tmp/machine-doc.env", ".env"])
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        #expect(detailed.droppedRepoLiterals == [])
    }

    @Test func repoLiteralAloneDenies() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try writeRepoPolicy(home: home, allowPaths: [".env"])
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        #expect(detailed.effective == .empty)
        #expect(detailed.droppedRepoLiterals == [".env"])
        let set = SecretAllowPaths.loadEffective(home: home, workspace: workspace)
        #expect(set == .empty)
        let rule = try #require(SecretPathCatalog.dayOne.firstMatch(of: "/tmp/rv-oracle/.env"))
        #expect(set.exempts("/tmp/rv-oracle/.env", rule: rule) == false)
    }

    @Test func blessedRepoLiteralTakesEffect() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try writeRepoPolicy(home: home, allowPaths: [".env"])
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try SecretAllowPaths.saveBlessPaths(
            [".env"],
            to: configDir.appendingPathComponent("config.json")
        )
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        #expect(detailed.effective.literals == [".env"])
        #expect(detailed.droppedRepoLiterals == [])
        let rule = try #require(SecretPathCatalog.dayOne.firstMatch(of: "/tmp/rv-oracle/.env"))
        #expect(detailed.effective.exempts("/tmp/rv-oracle/.env", rule: rule))
    }

    @Test(arguments: [
        #"{ "secret": { "bless_paths": "not-an-array" } }"#,
        #"{ "secret": { "bless_paths": [".env", 42] } }"#,
    ])
    func malformedBlessGateBlessesNothing(configJSON: String) throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try writeRepoPolicy(home: home, allowPaths: [".env"])
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(configJSON.utf8).write(to: configDir.appendingPathComponent("config.json"))
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        #expect(detailed.effective == .empty)
        #expect(detailed.droppedRepoLiterals == [".env"])
    }

    @Test func machineLiteralsNeedNoBlessing() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let workspace = try writeRepoPolicy(
            home: home,
            allowPaths: ["/tmp/machine.env", ".env"]
        )
        let configDir = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try SecretAllowPaths.saveMachineConfig(
            ["/tmp/machine.env"],
            to: configDir.appendingPathComponent("config.json")
        )
        try TypedRuleStore(baseDirectory: configDir).saveMachine(
            PolicyDocument(allowPaths: ["/tmp/machine-doc.env"])
        )
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        #expect(detailed.effective.literals == ["/tmp/machine.env", "/tmp/machine-doc.env"])
        #expect(detailed.droppedRepoLiterals == [".env"])
    }

    private func writeRepoPolicy(home: HomeDirectory, allowPaths: [String]) throws -> URL {
        let workspace = URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".rv", isDirectory: true),
            withIntermediateDirectories: true
        )
        let toml = "schema_version = 1\nsecret.allow_paths = ["
            + allowPaths.map { "\"\($0)\"" }.joined(separator: ", ")
            + "]\n"
        try Data(toml.utf8).write(to: workspace.appendingPathComponent(".rv/policy.toml"))
        return workspace
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
