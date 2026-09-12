import Foundation
import Testing
import RVHistory
import RVPolicy
@testable import RVCLI

struct BlocksCommandTests {
    @Test func registeredAndEmptyIsQuiet() throws {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("blocks"))
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        #expect(BlocksRun.list(home: home, json: false) == "")
        #expect(BlocksRun.list(home: home, json: true) == "[]\n")
    }

    @Test func listsNewestFirstAndJSON() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        ledger.append(
            DenialLedgerRecord(
                timestamp: now.addingTimeInterval(-5),
                host: "claude",
                tool: "Read",
                ruleID: "core.secrets:env",
                category: "environment",
                path: "/tmp/rv-oracle/.env"
            ),
            now: now
        )
        ledger.append(
            DenialLedgerRecord(
                timestamp: now,
                host: "cursor",
                tool: "Read",
                ruleID: "core.secrets:id-ed25519",
                category: "ssh",
                path: "~/.ssh/id_ed25519"
            ),
            now: now
        )
        let pretty = BlocksRun.list(home: home, json: false, now: now)
        let first = pretty.split(separator: "\n").first.map(String.init) ?? ""
        #expect(first.contains("core.secrets:id-ed25519"))
        #expect(pretty.contains("core.secrets:env"))
        let json = BlocksRun.list(home: home, json: true, now: now)
        #expect(json.contains("\"rule_id\":\"core.secrets:id-ed25519\""))
        #expect(json.contains("git reset") == false)
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-blocks-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
