import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPacks
import RVPolicy
import RVService
@testable import RVCLI

/// G4: `rv packs test <pack>` runs a pack's examples and shows each rule.
@Suite("rv packs test")
struct PacksTestCommandTests {
    @Test func redis_passes_andOffersToTurnItOn() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let command = try Packs.TestPack.parse(["database.redis", "--plain", "--no-color"])
            await #expect(throws: ExitCode(0)) {
                try await command.run()
            }
        }
        let lines = capture.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains { $0.hasPrefix("  ✓ flushall ") && $0.hasSuffix("stops 1 · allows 2") })
        #expect(lines.contains { $0.hasPrefix("  – stdin-unverified ") && $0.hasSuffix("no examples") })
        #expect(lines.filter { $0.isEmpty == false }.last == "  ✓ Ready. rv protect redis")
    }

    @Test func packOn_readyHasNoCommand() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let command = try Packs.TestPack.parse(["core.git", "--plain", "--no-color"])
            await #expect(throws: ExitCode(0)) {
                try await command.run()
            }
        }
        #expect(capture.stdout.hasSuffix("  ✓ Ready.\n"))
    }

    @Test func unknownPack_suggestsTheNearest() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let command = try Packs.TestPack.parse(["database.rediss"])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
        #expect(capture.stderr == "rv: no pack is named database.rediss. Did you mean database.redis? rv packs --all lists every pack.\n")
    }

    @Test func json_reportsEveryRule() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let command = try Packs.TestPack.parse(["database.redis", "--json"])
            await #expect(throws: ExitCode(0)) {
                try await command.run()
            }
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(capture.stdout.utf8)) as? [String: Any])
        #expect(object["schema"] as? String == "rv.packs.test.v1")
        #expect(object["passed"] as? Bool == true)
        let rules = try #require(object["rules"] as? [[String: Any]])
        #expect(rules.contains { $0["rule_id"] as? String == "database.redis:flushall" })
    }

    /// A stop example rv lets run, and an allow example rv stops, both fail.
    @Test func brokenExamples_fail() throws {
        var redis = try PackRegistry.loadDocument(PackID(rawValue: "database.redis"))
        let index = try #require(redis.guidance.firstIndex { $0.ruleID.pattern == "flushall" })
        redis.guidance[index].examples = RuleExamples(stop: ["redis-cli INFO keyspace"], allow: ["redis-cli FLUSHALL"])
        let documents = try PackRegistry.loadAllDocuments().map { $0.id == redis.id ? redis : $0 }
        let runs = try #require(PackProbe(documents: documents).runExamples(of: redis.id))
        let flushall = try #require(runs.first { $0.ruleID.pattern == "flushall" })
        #expect(flushall.failures == [
            .init(label: .stop, command: "redis-cli INFO keyspace", got: "ran"),
            .init(label: .allow, command: "redis-cli FLUSHALL", got: "stopped by database.redis:flushall"),
        ])
        let model = PackTestReport.model(packID: redis.id, runs: runs, enabled: false)
        #expect(model.failedCount == 1)
        #expect(model.rules.first { $0.name == "flushall" }?.failures == [
            "stop: redis-cli INFO keyspace ran", "allow: redis-cli FLUSHALL stopped by database.redis:flushall",
        ])
    }

    /// Gate: every bundled pack passes its own test, as RuleGuidanceTests
    /// proves for the catalog.
    @Test func everyBundledPack_passes() throws {
        let probe = try PackProbe.bundled()
        for id in probe.packIDs {
            let runs = try #require(probe.runExamples(of: id))
            for run in runs where run.passed == false {
                Issue.record("\(run.ruleID.rawValue): \(run.failures)")
            }
        }
    }
}
