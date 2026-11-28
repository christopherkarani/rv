import Foundation
import RVDomain
import RVHooks
import RVPolicy
@testable import RVService
import Testing

/// B4: the facts rvd puts in the session-start house rules.
struct HouseRulesGatherTests {
    @Test func modeFollowsThisHostsGuardMode() throws {
        let (home, _) = try Self.fixture(config: #"{"guard":{"mode":"enforce","hosts":{"claude":"observe"}}}"#)
        #expect(HouseRules.gather(home: home, cwd: nil, host: .claude, environment: [:]).mode == .watching)
        #expect(HouseRules.gather(home: home, cwd: nil, host: .codex, environment: [:]).mode == .guarding)
    }

    /// The answering process's launch environment can only tighten, so the
    /// mode named is the one the door enforces.
    @Test func launchEnvironmentPinningEnforce_saysGuarding() throws {
        let (home, _) = try Self.fixture(config: #"{"guard":{"mode":"observe"}}"#)
        let rules = HouseRules.gather(
            home: home, cwd: nil, host: .claude, environment: ["RV_GUARD_MODE": "enforce"])
        #expect(rules.mode == .guarding)
    }

    /// Key names `rv run --secret` will deliver: not scoped to other
    /// agents, not expired. Values are never read.
    @Test func keysAreRunnableSecretNamesOnly() throws {
        let (home, _) = try Self.fixture(secrets: """
            {"version":1,"secrets":[
              {"name":"STRIPE_KEY","source":{"keychain":{"service":"rv","account":"STRIPE_KEY"}},"delivery":{"environment":{}}},
              {"name":"SCOPED","agents":["claude"],"source":{"keychain":{"service":"rv","account":"SCOPED"}},"delivery":{"environment":{}}},
              {"name":"OLD","expires":"2020-01-01T00:00:00Z","source":{"keychain":{"service":"rv","account":"OLD"}},"delivery":{"environment":{}}}
            ]}
            """)
        let rules = HouseRules.gather(home: home, cwd: nil, host: .claude, environment: [:])
        #expect(rules.keys == ["STRIPE_KEY"])
    }

    @Test func repoRulesComeFromTheSessionsRepo() throws {
        let (home, workspace) = try Self.fixture()
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "no-push-main"),
            predicate: .gitPush(force: .exactly(.forceWithLease), branch: "main"),
            verdict: .deny,
            origin: .repo
        )
        try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
            .saveRepo([rule], workspace: workspace)
        let cwd = try #require(WorkingDirectory(validating: workspace.path))
        let rules = HouseRules.gather(home: home, cwd: cwd, host: .claude, environment: [:])
        #expect(rules.repoRules == [HouseRules.RepoRule(verdict: .deny, id: rule.id)])
        #expect(rules.text.contains("repo: no core.git/no-push-main"))
    }

    /// The hook-local door hands a session start to rvd, which alone knows
    /// the mode its launch environment enforces.
    @Test func localDoorEscalatesSessionStart() async throws {
        let fixture = try LocalHookFixture()
        let outcome = await fixture.decider.decide(
            host: .claude, stdin: #"{"hook_event_name":"SessionStart","cwd":"\#(fixture.workspace)"}"#)
        #expect(outcome == .escalate(.houseRules))
    }

    private static func fixture(config: String? = nil, secrets: String? = nil) throws -> (HomeDirectory, URL) {
        let root = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: root.path))
        let directory = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let config {
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        }
        if let secrets {
            let file = directory.appendingPathComponent("secrets.json")
            try Data(secrets.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let workspace = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (home, workspace)
    }
}
