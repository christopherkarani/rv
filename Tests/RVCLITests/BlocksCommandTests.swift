import Foundation
import Testing
import RVDomain
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
                host: .hook(.claude),
                tool: .file(.read),
                ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
                category: .secret(.environment),
                path: "/tmp/rv-oracle/.env"
            ),
            now: now
        )
        ledger.append(
            DenialLedgerRecord(
                timestamp: now,
                host: .hook(.cursor),
                tool: .file(.read),
                ruleID: RuleID(pack: .coreSecrets, pattern: "id-ed25519"),
                category: .secret(.ssh),
                path: "~/.ssh/id_ed25519"
            ),
            now: now
        )
        let pretty = BlocksRun.list(home: home, json: false, now: now)
        let first = pretty.split(separator: "\n").first.map(String.init) ?? ""
        #expect(first.contains("core.secrets:id-ed25519"))
        #expect(
            first.contains("cursor  Read  core.secrets:id-ed25519  ssh  ~/.ssh/id_ed25519")
        )
        #expect(pretty.contains("core.secrets:env"))
        #expect(pretty.contains("claude  Read  core.secrets:env  environment  /tmp/rv-oracle/.env"))
        let json = BlocksRun.list(home: home, json: true, now: now)
        #expect(json.contains("\"rule_id\":\"core.secrets:id-ed25519\""))
        #expect(json.contains("\"host\":\"cursor\""))
        #expect(json.contains("\"tool\":\"Read\""))
        #expect(json.contains("\"category\":\"ssh\""))
        #expect(json.contains("git reset") == false)
    }

    @Test func fileToolPathEscapesControls() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "/tmp/p\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{202E}" + sentence
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        for tool in [LedgerTool.file(.read), .file(.edit), .file(.write)] {
            ledger.append(
                DenialLedgerRecord(
                    timestamp: now,
                    host: .hook(.cursor),
                    tool: tool,
                    ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
                    category: .secret(.environment),
                    path: raw
                ),
                now: now
            )
        }
        let pretty = BlocksRun.list(home: home, json: false, now: now)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(pretty.contains("\\u001b[2J"))
        #expect(pretty.contains("\\u2028"))
        #expect(pretty.contains("\\u202e"))
        #expect(pretty.contains("Read"))
        #expect(pretty.contains("Edit"))
        #expect(pretty.contains("Write"))
        let lines = pretty.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
        let json = BlocksRun.list(home: home, json: true, now: now)
        #expect(json.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(json.contains("\\u2028"))
        #expect(json.contains("\\u202e"))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.contains { $0["path"] as? String == raw && $0["tool"] as? String == "Read" })
        #expect(parsed.contains { $0["tool"] as? String == "Edit" })
        #expect(parsed.contains { $0["tool"] as? String == "Write" })
    }

    @Test func shellRuleIDEscapesControls() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "x\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{2029}" + sentence + "\u{202E}" + sentence
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        ledger.append(
            DenialLedgerRecord(
                timestamp: now,
                host: .hook(.cursor),
                tool: .bash,
                ruleID: RuleID(pack: .coreGit, pattern: raw),
                category: .pack(.coreGit),
                path: "git push"
            ),
            now: now
        )
        let pretty = BlocksRun.list(home: home, json: false, now: now)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(pretty.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(pretty.contains("core.git:"))
        #expect(pretty.contains("\\u001b[2J"))
        #expect(pretty.contains("\\u2028"))
        #expect(pretty.contains("\\u2029"))
        #expect(pretty.contains("\\u202e"))
        let lines = pretty.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
        let json = BlocksRun.list(home: home, json: true, now: now)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.first?["rule_id"] as? String == "core.git:\(raw)")
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-blocks-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
