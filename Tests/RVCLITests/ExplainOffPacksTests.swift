import Foundation
import Testing
import RVDomain
import RVPolicy
import RVService
import RVTheme
@testable import RVCLI

/// G2: `rv explain` names the packs that are off and would stop a command.
@Suite("Explain off packs")
struct ExplainOffPacksTests {
    @Test func explain_redisFlushall_namesTheRedisPackAndHowToTurnItOn() async throws {
        let result = try await explain("redis-cli FLUSHALL")
        #expect(result.stdout.contains("Decision: ALLOW"))
        #expect(result.stdout.contains("Packs that are off"))
        #expect(result.stdout.contains("Would stop if database.redis were on (database.redis:flushall)"))
        #expect(result.stdout.contains("$ rv packs enable database.redis"))
        #expect(result.exitCode == 0)
    }

    @Test func explain_offPacksSitBeforeNext() async throws {
        let result = try await explain("docker system prune my-app")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let off = try #require(lines.firstIndex { $0.contains("Packs that are off") })
        #expect(lines[off...].contains { $0.contains("containers.docker") })
        if let next = lines.firstIndex(where: { $0.contains("Next") }) {
            #expect(next > off)
        }
    }

    @Test func explain_json_carriesOffPacks() async throws {
        let result = try await explain("redis-cli FLUSHALL", json: true)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let rows = try #require(object["off_packs"] as? [[String: String]])
        #expect(rows.contains {
            $0 == ["pack_id": "database.redis", "rule_id": "database.redis:flushall",
                   "turn_on": "rv packs enable database.redis"]
        })
        #expect(object["schema"] as? String == "rv.explain.v1")
        #expect(object["decision"] as? String == "allow")
    }

    @Test func explain_plainCommand_hasNoOffPacks() async throws {
        let result = try await explain("ls -la")
        #expect(result.stdout.contains("Packs that are off") == false)
        let json = try await explain("ls -la", json: true)
        #expect(json.stdout.contains("off_packs") == false)
    }

    /// A deny already names its rule; the probe only speaks for commands
    /// that would run.
    @Test func explain_deny_hasNoOffPacks() async throws {
        let result = try await explain("git reset --hard")
        #expect(result.stdout.contains("Decision: DENY"))
        #expect(result.stdout.contains("Packs that are off") == false)
    }

    @Test func explain_packAlreadyOn_isNotListed() async throws {
        let home = try isolatedHome()
        try PacksConfigStore.save(PacksConfig(enabled: ["database.redis"]), home: home)
        let result = try await explain("redis-cli FLUSHALL", home: home)
        #expect(result.stdout.contains("Decision: DENY"))
        #expect(result.stdout.contains("Packs that are off") == false)
    }

    @Test func probe_skipsEnabledPacks_andMediumMatches() throws {
        let probe = try PackProbe.bundled()
        let hits = probe.offPacksThatWouldStop(ShellCommand(rawValue: "redis-cli FLUSHALL"), enabled: dayOnePackIDs)
        #expect(hits.map(\.packID.rawValue).contains("database.redis"))
        let none = probe.offPacksThatWouldStop(
            ShellCommand(rawValue: "redis-cli FLUSHALL"), enabled: dayOnePackIDs + [PackID(rawValue: "database.redis")])
        #expect(none.map(\.packID.rawValue).contains("database.redis") == false)
        #expect(probe.offPacksThatWouldStop(ShellCommand(rawValue: "redis-cli INFO keyspace"), enabled: dayOnePackIDs).isEmpty)
    }

    @Test func rows_turnOnCommand_usesTheVocabulary() {
        let rows = ExplainOffPacks.rows([
            OffPackHit(packID: PackID(rawValue: "containers.docker"), ruleID: RuleID(rawValue: "containers.docker:system-prune")!),
        ])
        #expect(rows.map(\.turnOn) == ["rv packs enable containers.docker"])
        #expect(rows.first?.display == "Would stop if containers.docker were on (containers.docker:system-prune)")
    }
}

private func explain(_ command: String, json: Bool = false, home: HomeDirectory? = nil) async throws -> CLIResult {
    let probe = ThemeProbeFactory.make(
        jsonFlag: json, robotFlag: false, plainFlag: json == false, noColorFlag: true,
        stdinIsTTY: true, stdoutIsTTY: true, environment: ["TERM": "xterm"])
    return try await CommandRun.run(
        kind: .explain,
        command: command,
        probe: probe,
        requested: .automatic,
        cwd: "/tmp/ws",
        allowOnceDirectory: try isolatedAllowOnceDirectory(),
        home: try home ?? isolatedHome()
    )
}
