import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVTheme
@testable import RVCLI

/// `rv log` end to end over a real ledger file.
@Suite("rv log command")
struct LogCommandTests {
    static let now = Date(timeIntervalSince1970: 1_795_357_800) // 2026-11-22 14:30 UTC

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// One stop, two watch-mode would-stops, two judge notes in shadow.
    static func seed(_ home: HomeDirectory) {
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        let rows: [DenialLedgerRecord] = [
            DenialLedgerRecord(timestamp: now.addingTimeInterval(-3 * 3600), host: .hook(.claude), tool: .bash,
                               ruleID: RuleID(pack: .coreJudge, pattern: "laya-block"), category: .pack(.coreJudge),
                               path: "", observed: true, session: "cc8a1"),
            DenialLedgerRecord(timestamp: now.addingTimeInterval(-2 * 3600), host: .hook(.cursor), tool: .file(.read),
                               ruleID: RuleID(pack: .coreSecrets, pattern: "env"), category: .secret(.environment),
                               path: "~/code/app/.env", observed: true, wouldBe: .ask),
            DenialLedgerRecord(timestamp: now.addingTimeInterval(-43 * 60), host: .hook(.codex), tool: .bash,
                               ruleID: RuleID(pack: .coreGit, pattern: "push-force-long"), category: .pack(.coreGit),
                               path: "", observed: true),
            DenialLedgerRecord(timestamp: now.addingTimeInterval(-32 * 60), host: .hook(.claude), tool: .bash,
                               ruleID: RuleID(pack: .coreJudge, pattern: "laya-block"), category: .pack(.coreJudge),
                               path: "", observed: true, session: "cc8a1"),
            DenialLedgerRecord(timestamp: now.addingTimeInterval(-28 * 60), host: .hook(.claude), tool: .bash,
                               ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), category: .pack(.coreGit),
                               path: "", session: "cc8a1"),
        ]
        for row in rows { ledger.append(row, now: now) }
    }

    func output(_ home: HomeDirectory, _ query: LogQuery = LogQuery(), json: Bool = false) throws -> String {
        try LogRun.output(home: home, query: query, json: json, palette: colorOffPalette, columns: 80,
                          now: Self.now, calendar: Self.utc)
    }

    @Test("rv log is registered next to rv blocks, and rv help log has its own page")
    func registered() throws {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("log") && names.contains("blocks"))
        #expect(CommandVocabulary.Command(rawValue: "log") == .log)
        #expect(CommandVocabulary.plannedNames.contains { $0.spelling == "rv log" } == false)
        #expect(HelpDispatch.topic(arguments: ["help", "log"]) == .log)
        #expect(HelpDispatch.topic(arguments: ["log", "--help"]) == .log)
        let parsed = try RV.parseAsRoot(["log", "--all", "--rule", "core.git", "--host", "claude", "--json"])
        let log = try #require(parsed as? Log)
        #expect(log.all && log.rule == "core.git" && log.host == "claude" && log.format.json)
    }

    @Test("plain text from the ledger: a stop and a would-stop differ, judge notes fold")
    func plainText() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        let text = try output(home)
        #expect(text.contains("\u{1B}") == false)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.allSatisfy { $0.count <= 80 })
        let stop = try #require(lines.first { $0.contains("core.git:reset-hard") })
        #expect(stop.contains("14:02") && stop.contains("claude") && stop.contains("✕ Stopped"))
        let watched = try #require(lines.first { $0.contains("core.git:push-force-long") })
        #expect(watched.contains("◐ Would stop") && watched.contains("✕") == false)
        #expect(lines.contains { $0.contains("…code/app/.env") })
        #expect(text.contains("laya-block") == false)
        #expect(text.contains("1 stopped · 2 would stop · judge: 2 notes in shadow, hidden"))
        #expect(lines.last { $0.isEmpty == false } == "  → rv log --all   every row, judge notes too")
        let all = try output(home, LogQuery(all: true))
        #expect(all.components(separatedBy: "core.judge:laya-block").count == 3)
    }

    @Test("the code column is the row's code, the same on every read")
    func codes() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        let records = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home)).records(asOf: Self.now)
        let codes = records.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(codes.allSatisfy { $0.wholeMatch(of: /[0-9a-f]{3}-[0-9a-f]{3}/) != nil })
        let text = try output(home, LogQuery(all: true))
        for code in codes { #expect(text.contains(code)) }
        #expect(try output(home, LogQuery(all: true)) == text)
    }

    @Test("--json is one stable object with the rows shown")
    func json() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        let text = try output(home, json: true)
        #expect(text.hasSuffix("}\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["schema"] as? String == "rv.log.v1")
        #expect(object["judge_notes_hidden"] as? Int == 2)
        let rows = try #require(object["rows"] as? [[String: Any]])
        #expect(rows.map { $0["verdict"] as? String } == ["stopped", "would_stop", "would_stop"])
        #expect(rows.first?["time"] as? String == "2026-11-22T14:02:00Z")
        #expect(rows.first?["session"] as? String == "cc8a1")
        #expect(Set(rows.flatMap(\.keys)).isSubset(of: [
            "time", "agent", "verdict", "rule", "command", "code", "tool", "target", "would_be", "session",
        ]))
        #expect(text.contains("\\/") == false)
    }

    @Test("an empty ledger and a filter that matches nothing each say so")
    func emptyStates() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        #expect(try output(home).contains("Nothing stopped, nothing would stop in the last 7 days."))
        Self.seed(home)
        let none = try output(home, LogQuery(host: "grok"))
        #expect(none.contains("Nothing matches."))
        #expect(none.hasSuffix("  → rv log   every row\n"))
    }

    @Test("rv blocks prints what it printed before rv log existed")
    func blocksUnchanged() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        let blocks = try BlocksRun.list(home: home, json: false, now: Self.now)
        // rv blocks lists every row, judge notes included, in its own words.
        #expect(blocks.components(separatedBy: "core.judge:laya-block").count == 3)
        #expect(blocks.contains("✕") == false && blocks.contains("◐") == false)
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-log-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
