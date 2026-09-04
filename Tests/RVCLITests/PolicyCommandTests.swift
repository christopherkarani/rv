import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

@Suite("PolicyCommand")
struct PolicyCommandTests {
    @Test func subcommandIsRegisteredOnRV() {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("policy"))
        #expect(Policy.configuration.commandName == "policy")
        let children = Policy.configuration.subcommands.map { $0.configuration.commandName }
        #expect(children == ["show"])
        #expect(children.contains("draft") == false)
        #expect(Policy.Show.configuration.commandName == "show")
    }

    @Test func helpListsPolicy() {
        #expect(RV.helpMessage().contains("policy"))
        #expect(Policy.helpMessage().contains("show"))
        #expect(Policy.helpMessage().contains("draft") == false)
    }

    @Test func emptyTempHomeNamesOriginsWithoutMinting() throws {
        try withTempPolicyContext { home, workspace in
            let snapshot = try PolicyShowRun.load(home: home, workspace: workspace)
            let text = PolicyShowRun.pretty(snapshot)

            #expect(originSection("builtin", in: text) == "  (none)")
            #expect(originSection("machine", in: text) == "  (none)")
            #expect(originSection("repo", in: text) == "  (none)")
            #expect(text.contains("core.git") == false)

            let config = RVPolicyPaths.configDirectory(home: home)
            #expect(FileManager.default.fileExists(atPath: config.path) == false)
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
    }

    @Test func listsMachineAndRepoSeparately() throws {
        try withTempPolicyContext { home, workspace in
            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
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

            let snapshot = try PolicyShowRun.load(home: home, workspace: workspace)
            let text = PolicyShowRun.pretty(snapshot)
            let builtin = try #require(originSection("builtin", in: text))
            let machine = try #require(originSection("machine", in: text))
            let repo = try #require(originSection("repo", in: text))

            #expect(builtin == "  (none)")
            #expect(machine.contains("core.git:force-push-main deny gitPush force=force branch=main"))
            #expect(machine.contains("force-push-main-allow") == false)
            #expect(repo.contains("core.git:force-push-main-allow allow gitPush force=force branch=main"))
            #expect(repo.contains("  (none)") == false)
        }
    }

    @Test func injectedBuiltinIsNamedWithoutWritingMachineFile() throws {
        try withTempPolicyContext { home, workspace in
            let builtin = TypedRule(
                id: RuleID(pack: .coreGit, pattern: "force-push-main-builtin"),
                predicate: .gitPush(force: .force, branch: "main"),
                verdict: .deny,
                origin: .builtin
            )
            let snapshot = try PolicyShowRun.load(
                home: home,
                workspace: workspace,
                builtin: [builtin]
            )
            let text = PolicyShowRun.pretty(snapshot)
            let section = try #require(originSection("builtin", in: text))
            #expect(section.contains("core.git:force-push-main-builtin deny gitPush force=force branch=main"))
            #expect(originSection("machine", in: text) == "  (none)")
            let config = RVPolicyPaths.configDirectory(home: home)
            #expect(
                FileManager.default.fileExists(
                    atPath: TypedRuleStore(baseDirectory: config).machineFileURL.path
                ) == false
            )
        }
    }

    @Test func robotNamesThreeOrigins() throws {
        try withTempPolicyContext { home, workspace in
            let json = try PolicyShowRun.robot(
                try PolicyShowRun.load(home: home, workspace: workspace)
            )
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let dictionary = try #require(object as? [String: Any])
            #expect(dictionary["builtin"] as? [Any] != nil)
            #expect(dictionary["machine"] as? [Any] != nil)
            #expect(dictionary["repo"] as? [Any] != nil)
            #expect((dictionary["builtin"] as? [Any])?.isEmpty == true)
            #expect((dictionary["machine"] as? [Any])?.isEmpty == true)
            #expect((dictionary["repo"] as? [Any])?.isEmpty == true)
            #expect(dictionary["english"] == nil)

            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            let machineRule = TypedRule(
                id: RuleID(pack: .coreGit, pattern: "force-push-main"),
                predicate: .gitPush(force: .force, branch: "main"),
                verdict: .deny,
                origin: .machine
            )
            try store.saveMachine([machineRule])

            let populatedJSON = try PolicyShowRun.robot(
                try PolicyShowRun.load(home: home, workspace: workspace)
            )
            let populatedObject = try JSONSerialization.jsonObject(
                with: Data(populatedJSON.utf8)
            )
            let populated = try #require(populatedObject as? [String: Any])
            #expect(populated["english"] == nil)
            let machineRows = try #require(populated["machine"] as? [[String: Any]])
            #expect(machineRows.count == 1)
            #expect(machineRows[0]["predicate"] is String == false)

            let decoded = try JSONDecoder().decode(
                PolicyShowSnapshot.self,
                from: Data(populatedJSON.utf8)
            )
            #expect(decoded.machine == [machineRule])
            #expect(decoded.machine[0].id == machineRule.id)
            #expect(decoded.machine[0].verdict == .deny)
            #expect(decoded.machine[0].predicate == .gitPush(force: .force, branch: "main"))
        }
    }

    @Test func invalidMachineFileFailsClosed() throws {
        try withTempPolicyContext { home, workspace in
            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            try FileManager.default.createDirectory(
                at: store.machineFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "not-json".write(to: store.machineFileURL, atomically: true, encoding: .utf8)
            #expect(throws: TypedRuleStoreError.invalidFile) {
                _ = try PolicyShowRun.load(home: home, workspace: workspace)
            }
        }
    }

}

private func withTempPolicyContext(_ body: (HomeDirectory, URL) throws -> Void) throws {
    let home = try isolatedHome()
    let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-policy-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: workspace)
    }
    try body(home, workspace)
}

private func originSection(_ origin: String, in text: String) -> String? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(of: origin) else { return nil }
    let tail = lines[(start + 1)...]
    let end = tail.firstIndex { line in
        line == "builtin" || line == "machine" || line == "repo"
    }
    let body = end.map { tail[..<$0] } ?? tail[...]
    return body
        .joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
}
