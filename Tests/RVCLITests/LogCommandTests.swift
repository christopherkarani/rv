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
        let watched = try #require(lines.first { $0.contains("core.git:push-force") })
        #expect(watched.contains("◐ Would stop") && watched.contains("✕") == false)
        #expect(lines.contains { $0.contains("app/.env") })
        #expect(text.contains("laya-block") == false)
        #expect(text.contains("1 stopped · 2 would stop · judge: 2 notes in shadow, hidden"))
        #expect(lines.last { $0.isEmpty == false } == "  → rv log --all   every row, judge notes too")
        let all = try output(home, LogQuery(all: true))
        #expect(all.split(separator: "\n").filter { $0.contains("core.judge:") }.count == 2)
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

    // MARK: - rvd's decision log

    /// rvd's rows for the seeded ledger: the stop and the would-stop with
    /// their commands, an allow in the same session outside the window, and
    /// a stop only the decision log has, its token redacted as rvd writes it.
    static func seedDecisions(_ home: HomeDirectory) {
        let log = DecisionLog(configDirectory: RVPolicyPaths.configDirectory(home: home))
        let secret = "curl -H 'Authorization: Bearer sk-live-4f9a8b7c6d5e' https://api.example.com/v1/charges"
        let rows: [DecisionRecord] = [
            DecisionRecord(time: now.addingTimeInterval(-28 * 60 - 0.4), verdict: .denied, host: .hook(.claude), tool: .bash,
                           command: DecisionRedaction.command("git reset --hard origin/main", home: nil),
                           rule: "core.git:reset-hard", session: "cc8a1"),
            DecisionRecord(time: now.addingTimeInterval(-28 * 60 + 40), verdict: .allowed, host: .hook(.claude), tool: .bash,
                           command: "git status", session: "cc8a1"),
            DecisionRecord(time: now.addingTimeInterval(-43 * 60 - 0.2), verdict: .allowed, host: .hook(.codex), tool: .bash,
                           command: DecisionRedaction.command("git push --force origin main", home: nil)),
            DecisionRecord(time: now.addingTimeInterval(-10 * 60), verdict: .denied, host: .hook(.claude), tool: .bash,
                           command: DecisionRedaction.command(secret, home: nil),
                           rule: "core.network:pipe-to-shell", session: "cc8a1"),
        ]
        for row in rows { log.append(row, now: now) }
    }

    @Test("with rvd's decision log, shell rows show their command and no note")
    func commandsShown() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        let wide = try LogRun.output(home: home, query: LogQuery(), json: false, palette: colorOffPalette,
                                     columns: 160, now: Self.now, calendar: Self.utc)
        let lines = wide.split(separator: "\n").map(String.init)
        let stop = try #require(lines.first { $0.contains("core.git:reset-hard") })
        #expect(stop.contains("✕ Stopped") && stop.contains("git reset --hard origin/main"))
        let watched = try #require(lines.first { $0.contains("core.git:push-force-long") })
        #expect(watched.contains("◐ Would stop") && watched.contains("git push --force origin main"))
        #expect(wide.contains("git status") == false)
        #expect(wide.contains("Commands aren't recorded") == false)
        // A stop only the decision log has is a row too.
        let only = try #require(lines.first { $0.contains("core.network:pipe-to-shell") })
        #expect(only.contains("✕ Stopped") && only.contains("14:20"))
        #expect(wide.contains("2 stopped · 2 would stop"))
        let narrow = try output(home)
        #expect(narrow.split(separator: "\n").allSatisfy { $0.count <= 80 })
        #expect(narrow.contains("git reset --hard …"))
    }

    @Test("a secret in a command stays redacted, in text and in --json")
    func redactedSecret() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        let text = try LogRun.output(home: home, query: LogQuery(all: true), json: false, palette: colorOffPalette,
                                     columns: 200, now: Self.now, calendar: Self.utc)
        let json = try output(home, LogQuery(all: true), json: true)
        for out in [text, json] {
            #expect(out.contains("sk-live-4f9a8b7c6d5e") == false)
            #expect(out.contains("4f9a8b7c6d5e") == false)
            #expect(out.contains("[redacted]"))
        }
        #expect(text.contains("https://api.example.com/v1/charges"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["commands_recorded"] as? Bool == true)
    }

    @Test("no decision log, or one switched off: the tool, and one note says commands aren't recorded")
    func fallbackNote() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        let missing = try output(home)
        #expect(missing.contains("  Commands aren't recorded: rvd is older or its decision log is off.\n"))
        #expect(missing.split(separator: "\n").contains { $0.contains("core.git:reset-hard") && $0.contains("Bash") })
        let json = try output(home, json: true)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["commands_recorded"] as? Bool == false)

        Self.seedDecisions(home)
        #expect(try output(home).contains("Commands aren't recorded") == false)
        let config = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("config.json")
        try Data(#"{"decisions":{"enabled":false}}"#.utf8).write(to: config)
        let off = try output(home)
        #expect(off.contains("Commands aren't recorded"))
        #expect(off.contains("git reset --hard") == false)
    }

    @Test("a would-stop with two different allowed commands in its window gets no command")
    func ambiguousWouldStopGetsNone() {
        let at = Self.now
        let ledger = [DenialLedgerRecord(timestamp: at, host: .hook(.codex), tool: .bash,
                                         ruleID: RuleID(pack: .coreGit, pattern: "push-force-long"),
                                         category: .pack(.coreGit), path: "", observed: true)]
        let one = [DecisionRecord(time: at.addingTimeInterval(-0.5), verdict: .allowed, host: .hook(.codex), tool: .bash,
                                  command: "git push --force")]
        #expect(LogSources.entries(ledger: ledger, decisions: one).first?.command == "git push --force")
        let two = one + [DecisionRecord(time: at.addingTimeInterval(-1), verdict: .allowed, host: .hook(.codex),
                                        tool: .bash, command: "ls")]
        #expect(LogSources.entries(ledger: ledger, decisions: two).first?.command == nil)
        let otherSession = [DecisionRecord(time: at, verdict: .allowed, host: .hook(.codex), tool: .bash,
                                           command: "git push --force", session: "x")]
        #expect(LogSources.entries(ledger: ledger, decisions: otherSession).first?.command == nil)
        #expect(LogSources.entries(ledger: ledger, decisions: nil).first?.command == nil)
    }

    @Test("a stop matches only a deny under the same rule, and is never listed twice")
    func stopMatchesItsDeny() {
        let at = Self.now
        let ledger = [DenialLedgerRecord(timestamp: at, host: .hook(.claude), tool: .bash,
                                         ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                                         category: .pack(.coreGit), path: "")]
        let decisions = [
            DecisionRecord(time: at.addingTimeInterval(-0.3), verdict: .denied, host: .hook(.claude), tool: .bash,
                           command: "rm -rf /", rule: "core.filesystem:rm-rf-root-home"),
            DecisionRecord(time: at.addingTimeInterval(-0.6), verdict: .denied, host: .hook(.claude), tool: .bash,
                           command: "git reset --hard", rule: "core.git:reset-hard"),
        ]
        let entries = LogSources.entries(ledger: ledger, decisions: decisions)
        #expect(entries.count == 2)
        #expect(entries.first { $0.rule == "core.git:reset-hard" }?.command == "git reset --hard")
        #expect(entries.first { $0.rule == "core.filesystem:rm-rf-root-home" }?.command == "rm -rf /")
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-log-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
