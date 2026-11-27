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
        #expect(text.contains("1 stopped · 2 would stop · 2 judge notes in shadow"))
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

    /// rvd's rows for the seeded ledger, timed as production writes them
    /// (fractional seconds; the ledger keeps whole ones) and carrying the
    /// ids their ledger rows carry. An allow without a would-be is not a
    /// row; a stop whose ledger row was pruned still is.
    static func seedDecisions(_ home: HomeDirectory) {
        let config = RVPolicyPaths.configDirectory(home: home)
        let log = DecisionLog(configDirectory: config)
        let ledger = DenialLedger(configDirectory: config)
        let secret = "curl -H 'Authorization: Bearer sk-live-4f9a8b7c6d5e' https://api.example.com/v1/charges"
        func watched(_ rule: String, ask: Bool = false) -> DecisionWouldBe {
            DecisionWouldBe(verdict: .denied, rule: rule, ask: ask)
        }
        let rows: [DecisionRecord] = [
            DecisionRecord(time: now.addingTimeInterval(-3 * 3600 + 0.218), verdict: .allowed, host: .hook(.claude),
                           tool: .bash, command: "npm run build", session: "cc8a1", id: "0d14e2000001",
                           wouldBe: watched("core.judge:laya-block")),
            DecisionRecord(time: now.addingTimeInterval(-2 * 3600 + 0.731), verdict: .allowed, host: .hook(.cursor),
                           tool: .file(.read), path: "~/code/app/.env", id: "e410b7000002",
                           wouldBe: watched("core.secrets:env", ask: true)),
            DecisionRecord(time: now.addingTimeInterval(-43 * 60 + 0.402), verdict: .allowed, host: .hook(.codex),
                           tool: .bash, command: DecisionRedaction.command("git push --force origin main", home: nil),
                           id: "b207de000003", wouldBe: watched("core.git:push-force-long")),
            DecisionRecord(time: now.addingTimeInterval(-32 * 60 + 0.090), verdict: .allowed, host: .hook(.claude),
                           tool: .bash, command: "make release", session: "cc8a1", id: "5f3c19000004",
                           wouldBe: watched("core.judge:laya-block")),
            DecisionRecord(time: now.addingTimeInterval(-28 * 60 + 0.413), verdict: .denied, host: .hook(.claude),
                           tool: .bash, command: DecisionRedaction.command("git reset --hard origin/main", home: nil),
                           rule: "core.git:reset-hard", session: "cc8a1", id: "a7c835000005"),
            DecisionRecord(time: now.addingTimeInterval(-27 * 60 + 0.006), verdict: .allowed, host: .hook(.claude),
                           tool: .bash, command: "git status", session: "cc8a1", id: "77ea01000006"),
            // The secret is written raw here, as an older redactor might
            // have left it: rv log redacts again on read.
            DecisionRecord(time: now.addingTimeInterval(-10 * 60 + 0.555), verdict: .denied, host: .hook(.claude),
                           tool: .bash, command: secret, rule: "core.network:pipe-to-shell", session: "cc8a1",
                           id: "9ac2f0000007"),
        ]
        for row in rows { log.append(row, now: now) }
        // The ledger rows already seeded get their calls' ids.
        let ids = ["0d14e2000001", "e410b7000002", "b207de000003", "5f3c19000004", "a7c835000005"]
        let seeded = ledger.records(asOf: now).reversed()
        let path = DenialLedgerPaths(configDirectory: config).fileURL
        try? FileManager.default.removeItem(at: path)
        for (record, id) in zip(seeded, ids) {
            var record = record
            record.id = id
            ledger.append(record, now: now)
        }
    }

    func wide(_ home: HomeDirectory, _ query: LogQuery = LogQuery()) throws -> String {
        try LogRun.output(home: home, query: query, json: false, palette: colorOffPalette, columns: nil,
                          now: Self.now, calendar: Self.utc)
    }

    @Test("with rvd's decision log: one source, each stop once, the exact text")
    func decisionLogGolden() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        #expect(try output(home) == Self.decisionGolden80)
        #expect(try wide(home) == Self.decisionGoldenPiped)
    }

    static let decisionGolden80 = """

  ◆ today                                                                      4

  14:20  claude  ✕ Stopped     core.network:pipe-t…  curl -H 'Authoriz…  9ac-2f0
  14:02  claude  ✕ Stopped     core.git:reset-hard   git reset --hard …  a7c-835
  13:47  codex   ◐ Would stop  core.git:push-force…  git push --force …  b20-7de
  12:30  cursor  ◐ Would stop  core.secrets:env      Read …ode/app/.env  e41-0b7

  2 stopped · 2 would stop · 2 judge notes in shadow

  → rv log --all   every row, judge notes too

"""

    static let decisionGoldenPiped = """

  ◆ today                                                                                                                                           4

  14:20  claude  ✕ Stopped     core.network:pipe-to-shell  curl -H 'Authorization: [redacted] [redacted]' https://api.example.com/v1/charges  9ac-2f0
  14:02  claude  ✕ Stopped     core.git:reset-hard         git reset --hard origin/main                                                       a7c-835
  13:47  codex   ◐ Would stop  core.git:push-force-long    git push --force origin main                                                       b20-7de
  12:30  cursor  ◐ Would stop  core.secrets:env            Read ~/code/app/.env                                                               e41-0b7

  2 stopped · 2 would stop · 2 judge notes in shadow

  → rv log --all   every row, judge notes too

"""

    @Test("--json with the decision log: the exact object; command is null when none was recorded")
    func decisionLogJSON() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        #expect(try output(home, json: true) == Self.decisionJSON)
        let fallback = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: fallback.rawValue) }
        Self.seed(fallback)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(output(fallback, json: true).utf8)) as? [String: Any])
        let rows = try #require(object["rows"] as? [[String: Any]])
        #expect(rows.allSatisfy { $0["command"] is NSNull })
        #expect(rows.contains { $0["tool"] as? String == "Bash" })
        #expect(object["commands_recorded"] as? Bool == false)
    }

    static let decisionJSON = """
{"commands_recorded":true,"judge_notes_hidden":2,"matching":4,"rows":[{"agent":"claude","code":"9ac-2f0","command":"curl -H 'Authorization: [redacted] [redacted]' https://api.example.com/v1/charges","rule":"core.network:pipe-to-shell","session":"cc8a1","target":"","time":"2026-11-22T14:20:00Z","tool":"Bash","verdict":"stopped","would_be":null},{"agent":"claude","code":"a7c-835","command":"git reset --hard origin/main","rule":"core.git:reset-hard","session":"cc8a1","target":"","time":"2026-11-22T14:02:00Z","tool":"Bash","verdict":"stopped","would_be":null},{"agent":"codex","code":"b20-7de","command":"git push --force origin main","rule":"core.git:push-force-long","session":null,"target":"","time":"2026-11-22T13:47:00Z","tool":"Bash","verdict":"would_stop","would_be":"deny"},{"agent":"cursor","code":"e41-0b7","command":null,"rule":"core.secrets:env","session":null,"target":"~/code/app/.env","time":"2026-11-22T12:30:00Z","tool":"Read","verdict":"would_stop","would_be":"ask"}],"schema":"rv.log.v1","skipped_days":[],"stopped":2,"would_stop":2}

"""

    @Test("a secret in a command stays redacted, in text and in --json, even if the row kept it")
    func redactedSecret() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        let text = try wide(home, LogQuery(all: true))
        let json = try output(home, LogQuery(all: true), json: true)
        for out in [text, json] {
            #expect(out.contains("sk-live-4f9a8b7c6d5e") == false)
            #expect(out.contains("4f9a8b7c6d5e") == false)
            #expect(out.contains("[redacted]"))
        }
        #expect(text.contains("https://api.example.com/v1/charges"))
    }

    @Test("no decision log, or one switched off: the ledger, and the summary says commands aren't recorded")
    func fallbackNote() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        let missing = try output(home)
        #expect(missing.contains("  1 stopped · 2 would stop · 2 judge notes in shadow · commands not recorded\n"))
        #expect(missing.split(separator: "\n").contains { $0.contains("core.git:reset-hard") && $0.contains("Bash") })

        Self.seedDecisions(home)
        #expect(try output(home).contains("not recorded") == false)
        let config = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("config.json")
        try Data(#"{"decisions":{"enabled":false}}"#.utf8).write(to: config)
        let off = try output(home)
        #expect(off.contains("commands not recorded"))
        #expect(off.contains("git reset --hard") == false)
        #expect(off.contains("pipe-to-shell") == false)
    }

    @Test("piped output keeps every command whole, so grep finds it")
    func pipedIsWhole() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        let text = try wide(home)
        #expect(text.contains("…") == false)
        #expect(text.split(separator: "\n").contains { $0.contains("git reset --hard origin/main") && $0.hasSuffix("a7c-835") })
    }

    @Test("glyphs are coloured at a TTY, and plain when piped, under NO_COLOR or TERM=dumb")
    func colourFollowsTheTerminal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        func probe(tty: Bool, noColorEnv: Bool = false, termDumb: Bool = false) -> ThemeProbe {
            ThemeProbe(
                terminal: TTYPair(stdinIsTTY: tty, stdoutIsTTY: tty),
                forbid: OutputForbid(
                    json: false, robot: false, plain: false, ci: false,
                    noColor: OutputForbid.NoColor(flag: false, env: noColorEnv, termDumb: termDumb)
                ),
                columns: 100
            )
        }
        func render(_ probe: ThemeProbe) throws -> String {
            try LogRun.output(
                home: home, query: LogQuery(), json: false,
                palette: LogRun.palette(for: CLIAppearance.resolve(probe: probe, requested: .automatic)),
                columns: LogRun.columns(stdoutIsTTY: probe.stdoutIsTTY, probe: probe),
                now: Self.now, calendar: Self.utc
            )
        }
        let ink = Palette(for: ColorCapability(colorsEnabled: true))
        let tty = try render(probe(tty: true))
        #expect(tty.contains(ink.deny + "✕ Stopped" + ink.reset))
        #expect(tty.contains(ink.mark + "◐ Would stop" + ink.reset))
        #expect(tty.contains(ink.trace + "→" + ink.reset))
        #expect(tty.contains(ink.heading + "◆" + ink.reset))
        for plain in [probe(tty: false), probe(tty: true, noColorEnv: true), probe(tty: true, termDumb: true)] {
            let text = try render(plain)
            #expect(text.contains("\u{1B}") == false)
            #expect(text.contains("✕ Stopped") && text.contains("◐ Would stop") && text.contains("→ rv log --all"))
        }
    }

    // MARK: - Joining the ledger: on id only

    static func ledgerRow(_ at: Date, rule: String, observed: Bool = false, id: String?) -> DenialLedgerRecord {
        let parts = rule.split(separator: ":")
        return DenialLedgerRecord(
            timestamp: at, host: .hook(.claude), tool: .bash,
            ruleID: RuleID(pack: PackID(rawValue: String(parts[0])), pattern: String(parts[1])),
            category: .pack(PackID(rawValue: String(parts[0]))), path: "", observed: observed, session: "cc8a1", id: id
        )
    }

    static func decision(_ at: Date, _ verdict: DecisionVerdict, _ command: String, rule: String, id: String?)
        -> DecisionRecord
    {
        DecisionRecord(
            time: at, verdict: verdict, host: .hook(.claude), tool: .bash, command: command,
            rule: verdict == .allowed ? nil : rule, session: "cc8a1", id: id,
            wouldBe: verdict == .allowed ? DecisionWouldBe(verdict: .denied, rule: rule) : nil
        )
    }

    @Test("a stop in both files is one row, with the decision log's command")
    func duplicatesListOnce() {
        let at = Self.now.addingTimeInterval(0.731)
        let decisions = DecisionLogStops(records: [
            Self.decision(at, .denied, "git reset --hard", rule: "core.git:reset-hard", id: "a7c835000001"),
            Self.decision(at.addingTimeInterval(1), .refused, "make", rule: "rv.indeterminate:timeout", id: "a7c835000002"),
        ], startedAt: at.addingTimeInterval(-3600))
        let ledger = [
            Self.ledgerRow(Self.now, rule: "core.git:reset-hard", id: "a7c835000001"),
            Self.ledgerRow(Self.now.addingTimeInterval(1), rule: "rv.indeterminate:timeout", id: "a7c835000002"),
        ]
        let entries = LogSources.entries(ledger: ledger, decisions: decisions, home: nil)
        #expect(entries.count == 2)
        #expect(entries.map(\.command) == ["git reset --hard", "make"])
        #expect(entries.map(\.code) == ["a7c-835", "a7c-835"])
    }

    @Test("two would-stops a moment apart keep their own commands, whatever the ledger's times say")
    func swapsCannotHappen() {
        let at = Self.now.addingTimeInterval(0.913)
        let decisions = DecisionLogStops(records: [
            Self.decision(at, .allowed, "rm -rf ./dist", rule: "core.filesystem:rm-rf-general", id: "111111000001"),
            Self.decision(at.addingTimeInterval(0.4), .allowed, "git push --force", rule: "core.git:push-force-long",
                          id: "222222000002"),
        ], startedAt: at.addingTimeInterval(-3600))
        // The ledger's whole seconds put them the other way round.
        let ledger = [
            Self.ledgerRow(Self.now.addingTimeInterval(2), rule: "core.filesystem:rm-rf-general", observed: true,
                           id: "111111000001"),
            Self.ledgerRow(Self.now, rule: "core.git:push-force-long", observed: true, id: "222222000002"),
        ]
        let entries = LogSources.entries(ledger: ledger, decisions: decisions, home: nil)
        #expect(entries.count == 2)
        let pairs = Dictionary(uniqueKeysWithValues: entries.map { ($0.rule, $0.command) })
        #expect(pairs["core.filesystem:rm-rf-general"] == "rm -rf ./dist")
        #expect(pairs["core.git:push-force-long"] == "git push --force")
        #expect(entries.allSatisfy { $0.stopped == false })
    }

    @Test("the ledger adds only rows the decision log lacks: an id it has not, or a row from before it began")
    func ledgerFillsOnlyGaps() {
        let began = Self.now.addingTimeInterval(-3600)
        let decisions = DecisionLogStops(records: [
            Self.decision(Self.now, .denied, "git reset --hard", rule: "core.git:reset-hard", id: "a7c835000001"),
        ], startedAt: began)
        let ledger = [
            // Its decision row was lost: listed, without a command.
            Self.ledgerRow(Self.now.addingTimeInterval(-60), rule: "core.git:clean-force", id: "c1ea00000002"),
            // No id, after the log began: the log has it; never matched on time.
            Self.ledgerRow(Self.now, rule: "core.git:reset-hard", id: nil),
            // No id, before the log began: only the ledger has it.
            Self.ledgerRow(began.addingTimeInterval(-60), rule: "core.git:branch-force-delete", id: nil),
        ]
        let entries = LogSources.entries(ledger: ledger, decisions: decisions, home: nil)
        #expect(entries.map(\.rule).sorted() == ["core.git:branch-force-delete", "core.git:clean-force", "core.git:reset-hard"])
        #expect(entries.first { $0.rule == "core.git:reset-hard" }?.command == "git reset --hard")
        #expect(entries.first { $0.rule == "core.git:clean-force" }?.command == nil)
        // No decision log at all: the ledger as it is.
        #expect(LogSources.entries(ledger: ledger, decisions: nil, home: nil).count == 3)
        // A plain allow is never a row.
        let allow = DecisionRecord(time: Self.now, verdict: .allowed, host: .hook(.claude), tool: .bash, command: "ls")
        #expect(LogSources.entry(allow, home: nil) == nil)
    }

    @Test("a decision-log day too large to read is named in one dim line")
    func oversizedDayWarns() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        Self.seed(home)
        Self.seedDecisions(home)
        let log = DecisionLog(configDirectory: RVPolicyPaths.configDirectory(home: home))
        let big = log.fileURL(day: "2026-11-21")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(DecisionLog.maxFileBytes + 1))
        try handle.close()
        let text = try output(home)
        #expect(text.contains("  Skipped 1 decision-log day over 64 MB: 2026-11-21.\n"))
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-log-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
