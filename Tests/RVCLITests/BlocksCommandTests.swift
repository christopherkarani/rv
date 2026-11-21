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
        #expect(try BlocksRun.list(home: home, json: false) == "No denials in the last 7 days.\n")
        #expect(try BlocksRun.list(home: home, json: true) == "[]\n")
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
        let pretty = try BlocksRun.list(home: home, json: false, now: now)
        let rows = try dataRows(pretty)
        #expect(rows.count == 2)
        #expect(Array(rows[0].dropFirst()) == ["BLOCKED", "cursor", "Read", "core.secrets:id-ed25519", "~/.ssh/id_ed25519"])
        #expect(Array(rows[1].dropFirst()) == ["BLOCKED", "claude", "Read", "core.secrets:env", "/tmp/rv-oracle/.env"])
        #expect(pretty.contains("By rule: core.secrets:env 1 · core.secrets:id-ed25519 1"))
        let json = try BlocksRun.list(home: home, json: true, now: now)
        #expect(json.contains("\"rule_id\":\"core.secrets:id-ed25519\""))
        #expect(json.contains("\"host\":\"cursor\""))
        #expect(json.contains("\"tool\":\"Read\""))
        #expect(json.contains("\"category\":\"ssh\""))
        #expect(json.contains("/tmp/rv-oracle/.env"))
        #expect(json.contains("\\/tmp") == false)
        #expect(json.contains("git reset") == false)
    }

    /// Observed rows (observe mode: the agent was not blocked) say so in the
    /// text output too, in their own column before the host.
    @Test func observedRowsAreMarked() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        ledger.append(
            DenialLedgerRecord(
                timestamp: now.addingTimeInterval(-5),
                host: .hook(.cursor),
                tool: .bash,
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                category: .pack(.coreGit),
                path: "git reset --hard"
            ),
            now: now
        )
        ledger.append(
            DenialLedgerRecord(
                timestamp: now,
                host: .hook(.claude),
                tool: .bash,
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                category: .pack(.coreGit),
                path: "git reset --hard",
                observed: true
            ),
            now: now
        )
        let rows = try dataRows(try BlocksRun.list(home: home, json: false, now: now))
        #expect(rows.count == 2)
        #expect(Array(rows[0].dropFirst()) == ["WOULD BLOCK", "claude", "Bash", "core.git:reset-hard", "git reset --hard"])
        #expect(Array(rows[1].dropFirst()) == ["BLOCKED", "cursor", "Bash", "core.git:reset-hard", "git reset --hard"])
    }

    /// A row that names its agent session prints it last (`session=<id>`)
    /// and carries `session` in JSON; rows without one are unchanged.
    @Test func sessionIsShownWhenRecorded() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        func record(_ offset: TimeInterval, session: String?) -> DenialLedgerRecord {
            DenialLedgerRecord(
                timestamp: now.addingTimeInterval(offset), host: .hook(.claude), tool: .bash,
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), category: .pack(.coreGit),
                path: "", session: session
            )
        }
        ledger.append(record(-5, session: nil), now: now)
        ledger.append(record(0, session: "0b7f3c2e-1d2a"), now: now)
        let rows = try dataRows(try BlocksRun.list(home: home, json: false, now: now))
        #expect(rows.count == 2)
        #expect(rows[0].last == "session=0b7f3c2e-1d2a")
        #expect(rows[1].last == "core.git:reset-hard")
        let json = try BlocksRun.list(home: home, json: true, now: now)
        let jsonRows = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(jsonRows[0]["session"] as? String == "0b7f3c2e-1d2a")
        #expect(jsonRows[1]["session"] == nil)
    }

    /// Observed would-ask rows (enforcement would have asked a human) say
    /// `observed ask`; would-deny rows keep printing `observed`. JSON
    /// carries `would_be` on observed rows only.
    @Test func observedWouldAskRowsAreDistinct() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        func record(_ offset: TimeInterval, _ host: HookHost, observed: Bool, wouldBe: LedgerWouldBe) -> DenialLedgerRecord {
            DenialLedgerRecord(
                timestamp: now.addingTimeInterval(offset),
                host: .hook(host),
                tool: .bash,
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                category: .pack(.coreGit),
                path: "",
                observed: observed,
                wouldBe: wouldBe
            )
        }
        ledger.append(record(-10, .cursor, observed: false, wouldBe: .deny), now: now)
        ledger.append(record(-5, .codex, observed: true, wouldBe: .deny), now: now)
        ledger.append(record(0, .claude, observed: true, wouldBe: .ask), now: now)
        let rows = try dataRows(try BlocksRun.list(home: home, json: false, now: now))
        #expect(rows.count == 3)
        #expect(Array(rows[0].dropFirst()) == ["WOULD ASK", "claude", "Bash", "core.git:reset-hard"])
        #expect(Array(rows[1].dropFirst()) == ["WOULD BLOCK", "codex", "Bash", "core.git:reset-hard"])
        #expect(Array(rows[2].dropFirst()) == ["BLOCKED", "cursor", "Bash", "core.git:reset-hard"])
        let json = try BlocksRun.list(home: home, json: true, now: now)
        let jsonRows = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        #expect(jsonRows.count == 3)
        #expect(jsonRows[0]["would_be"] as? String == "ask")
        #expect(jsonRows[0]["observed"] as? Bool == true)
        #expect(jsonRows[1]["would_be"] as? String == "deny")
        #expect(jsonRows[2]["would_be"] == nil)
        #expect(jsonRows[2]["observed"] == nil)
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
        let pretty = try BlocksRun.list(home: home, json: false, now: now)
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
        let json = try BlocksRun.list(home: home, json: true, now: now)
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
        let pretty = try BlocksRun.list(home: home, json: false, now: now)
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
        let json = try BlocksRun.list(home: home, json: true, now: now)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.first?["rule_id"] as? String == "core.git:\(raw)")
    }

    @Test func defaultLimitFiltersAndSummary() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
        for index in 0..<25 {
            ledger.append(
                DenialLedgerRecord(
                    timestamp: now.addingTimeInterval(TimeInterval(-index)),
                    host: .hook(index == 0 ? .codex : .claude), tool: .bash,
                    ruleID: RuleID(pack: index < 3 ? .coreGit : .coreFilesystem, pattern: index < 3 ? "reset-hard" : "rm-rf"),
                    category: .pack(index < 3 ? .coreGit : .coreFilesystem), path: ""
                ),
                now: now
            )
        }
        let pretty = try BlocksRun.list(home: home, json: false, now: now)
        #expect(try dataRows(pretty).count == 20)
        #expect(pretty.contains("Showing the newest 20 of 25. rv blocks --all lists every one."))
        #expect(pretty.contains("By rule: core.filesystem:rm-rf 22 · core.git:reset-hard 3"))

        let all = try BlocksRun.list(home: home, json: false, options: .init(limit: nil), now: now)
        #expect(try dataRows(all).count == 25)
        #expect(all.contains("Showing") == false)

        let git = try BlocksRun.list(home: home, json: false, options: .init(rule: "core.git"), now: now)
        #expect(try dataRows(git).count == 3)
        let codex = try BlocksRun.list(home: home, json: true, options: .init(host: "CODEX"), now: now)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(codex.utf8)) as? [[String: Any]])
        #expect(parsed.count == 1)
        #expect(try BlocksRun.list(home: home, json: false, options: .init(host: "pi"), now: now).hasPrefix("No denials match."))
        // JSON is never cut by the text limit.
        let json = try BlocksRun.list(home: home, json: true, now: now)
        #expect((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])?.count == 25)
    }

    /// The table's data rows (after the header, before the blank line),
    /// each split into its cells.
    private func dataRows(_ text: String) throws -> [[String]] {
        let lines = text.components(separatedBy: "\n")
        let header = try #require(lines.first)
        #expect(header.hasPrefix("TIME"))
        return lines.dropFirst().prefix { $0.isEmpty == false }.map { line in
            line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
        }
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-blocks-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
