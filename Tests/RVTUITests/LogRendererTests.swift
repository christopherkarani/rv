import Foundation
import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

@Suite("rv log renderer")
struct LogRendererTests {
    static let now = Date(timeIntervalSince1970: 1_795_357_800) // 2026-11-22 14:30 UTC

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        now.addingTimeInterval(Double((hour - 14) * 3600 + (minute - 30) * 60 - daysAgo * 86_400))
    }

    /// A morning with real stops, watch-mode would-stops and a flood of
    /// judge notes in shadow.
    static let fixture: [LogEntry] = [
        LogEntry(time: at(14, 2), agent: "claude", stopped: true, rule: "core.git:reset-hard",
                 tool: "Bash", target: "", command: "git reset --hard origin/main", code: "a7c-835"),
        LogEntry(time: at(13, 58), agent: "claude", stopped: false, rule: "core.judge:laya-block", isJudge: true,
                 tool: "Bash", target: "", code: "0d1-4e2"),
        LogEntry(time: at(13, 47), agent: "codex", stopped: false, rule: "core.git:push-force-long",
                 tool: "Bash", target: "", command: "git push --force origin main", code: "b20-7de"),
        LogEntry(time: at(13, 31), agent: "claude", stopped: false, rule: "core.judge:laya-block", isJudge: true,
                 tool: "Bash", target: "", code: "5f3-c19"),
        LogEntry(time: at(12, 15), agent: "cursor", stopped: true, rule: "core.secrets:id-ed25519",
                 tool: "Read", target: "~/.ssh/id_ed25519", code: "e41-0b7"),
        LogEntry(time: at(11, 20), agent: "claude", stopped: false, rule: "core.filesystem:rm-rf-general",
                 tool: "Bash", target: "", command: "rm -rf ./dist ../dist", code: "9ac-2f0"),
        LogEntry(time: at(10, 5), agent: "claude", stopped: false, rule: "core.judge:laya-block", isJudge: true,
                 tool: "Bash", target: "", code: "77e-a01"),
        LogEntry(time: at(9, 12, daysAgo: 1), agent: "codex", stopped: false, wouldAsk: true, rule: "core.secrets:env",
                 tool: "Edit", target: "~/code/app/Sources/Payments/Internal/.env.production", code: "c08-d3a"),
    ]

    static func lines(_ query: LogQuery = LogQuery(), columns: Int? = 80, palette: Palette = colorOffPalette) -> [String] {
        let model = LogViewModel(entries: fixture, query: query, now: now, calendar: utc)
        return LogRenderer().render(LogFrame(model: model, columns: columns), palette: palette)
    }

    /// Every line fits `columns` in terminal cells and ends in no space.
    static func expectFits(_ rendered: [String], _ columns: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        for line in rendered {
            #expect(TerminalWidth.of(line) <= columns, "\(TerminalWidth.of(line)): \(line)", sourceLocation: sourceLocation)
            #expect(line.hasSuffix(" ") == false, "trailing space: \(line)", sourceLocation: sourceLocation)
        }
    }

    @Test("80 columns, no color: fixed columns, judge notes folded, one summary line")
    func goldenAt80() {
        let rendered = Self.lines()
        Self.expectFits(rendered, 80)
        #expect(rendered.joined(separator: "\n") == Self.golden80)
    }

    static let golden80 = """

          ◆ last 7 days                                                                5

          14:02  claude  ✕ Stopped     core.git:reset-hard   git reset --hard …  a7c-835
          13:47  codex   ◐ Would stop  core.git:push-force…  git push --force …  b20-7de
          12:15  cursor  ✕ Stopped     core.secrets:id-ed2…  Read …h/id_ed25519  e41-0b7
          11:20  claude  ◐ Would stop  core.filesystem:rm-…  rm -rf ./dist ../…  9ac-2f0
          Sat 21 Nov
          09:12  codex   ◐ Would stop  core.secrets:env      Edit …v.production  c08-d3a

          2 stopped · 3 would stop · 3 judge notes in shadow

          → rv log --all   every row, judge notes too
        """

    @Test("60 columns: the rule keeps its minimum, the code column goes, prose wraps")
    func goldenAt60() {
        let rendered = Self.lines(columns: 60)
        Self.expectFits(rendered, 60)
        let widths = LogRenderer.widths(
            LogViewModel(entries: Self.fixture, query: LogQuery(), now: Self.now, calendar: Self.utc).rows, columns: 60
        )
        #expect(widths.rule >= LogRenderer.minimumRule)
        #expect(widths.code == 0)
        #expect(widths.total <= 60)
        #expect(rendered.joined(separator: "\n") == Self.golden60)
    }

    static let golden60 = """

          ◆ last 7 days                                            5

          14:02  claude  ✕ Stopped     core.git:re…  git reset --ha…
          13:47  codex   ◐ Would stop  core.git:pu…  git push --for…
          12:15  cursor  ✕ Stopped     core.secret…  …ssh/id_ed25519
          11:20  claude  ◐ Would stop  core.filesy…  rm -rf ./dist …
          Sat 21 Nov
          09:12  codex   ◐ Would stop  core.secret…  …env.production

          2 stopped · 3 would stop · 3 judge notes in shadow

          → rv log --all   every row, judge notes too
        """

    @Test("120 columns: whole commands and rule ids; a file keeps the end of its path")
    func goldenAt120() {
        Self.expectFits(Self.lines(columns: 120), 120)
        #expect(Self.lines(columns: 120).joined(separator: "\n") == Self.golden120)
    }

    static let golden120 = """

          ◆ last 7 days                                                                                                        5

          14:02  claude  ✕ Stopped     core.git:reset-hard            git reset --hard origin/main                       a7c-835
          13:47  codex   ◐ Would stop  core.git:push-force-long       git push --force origin main                       b20-7de
          12:15  cursor  ✕ Stopped     core.secrets:id-ed25519        Read ~/.ssh/id_ed25519                             e41-0b7
          11:20  claude  ◐ Would stop  core.filesystem:rm-rf-general  rm -rf ./dist ../dist                              9ac-2f0
          Sat 21 Nov
          09:12  codex   ◐ Would stop  core.secrets:env               Edit …p/Sources/Payments/Internal/.env.production  c08-d3a

          2 stopped · 3 would stop · 3 judge notes in shadow

          → rv log --all   every row, judge notes too
        """

    @Test("piped (no width): every cell whole, nothing cut, so grep sees full commands")
    func piped() {
        let rendered = Self.lines(LogQuery(all: true), columns: nil)
        #expect(rendered.joined().contains("…") == false)
        #expect(rendered.contains { $0.contains("git reset --hard origin/main") && $0.hasSuffix("a7c-835") })
        #expect(rendered.contains { $0.contains("Edit ~/code/app/Sources/Payments/Internal/.env.production") })
        #expect(rendered.contains { $0.contains("core.filesystem:rm-rf-general") })
    }

    @Test("without rvd's decision log, shell rows show the tool and the summary says so on one line")
    func commandsNotRecorded() {
        let model = LogViewModel(
            entries: Self.fixture.map { entry in
                var entry = entry
                entry.command = nil
                return entry
            },
            query: LogQuery(), now: Self.now, calendar: Self.utc, commandsRecorded: false
        )
        let rendered = LogRenderer().render(LogFrame(model: model), palette: colorOffPalette)
        Self.expectFits(rendered, 80)
        #expect(rendered.contains { $0.hasPrefix("  14:02  claude  ✕ Stopped") && $0.contains("  Bash  ") })
        #expect(rendered.contains("  2 stopped · 3 would stop · 3 judge notes in shadow · commands not recorded"))
        let dim = Palette(for: ColorCapability(colorsEnabled: true))
        let painted = LogRenderer().render(LogFrame(model: model), palette: dim)
        #expect(painted.contains("  2 stopped · 3 would stop · 3 judge notes in shadow · commands not recorded"))
        #expect(Self.lines().contains { $0.contains("not recorded") } == false)
        // At 60 columns the summary wraps between its parts.
        let narrow = LogRenderer().render(LogFrame(model: model, columns: 60), palette: colorOffPalette)
        Self.expectFits(narrow, 60)
        #expect(narrow.contains("  2 stopped · 3 would stop · 3 judge notes in shadow"))
        #expect(narrow.contains("  commands not recorded"))
    }

    @Test("rows stay one line each and fit at any width; the command ends in … when cut")
    func narrowAndWide() {
        for columns in [60, 72, 80, 100, 120, 200] {
            let rendered = Self.lines(LogQuery(all: true), columns: columns)
            let rows = rendered.filter { $0.contains("Stopped") || $0.contains("Would stop") }
            #expect(rows.count == Self.fixture.count)
            Self.expectFits(rendered, columns)
        }
        let narrow = Self.lines(columns: 80).joined(separator: "\n")
        #expect(narrow.contains("…"))
        let wide = Self.lines(columns: 200).joined(separator: "\n")
        #expect(wide.contains("Edit ~/code/app/Sources/Payments/Internal/.env.production"))
    }

    @Test("wide characters count two columns, so a row still fits")
    func displayWidth() {
        let model = LogViewModel(
            entries: [LogEntry(time: Self.at(14, 0), agent: "claude", stopped: true, rule: "core.git:reset-hard",
                               tool: "Bash", target: "", command: "echo 日本語のコミットメッセージ && git reset --hard 🚀🚀",
                               code: "abc-def")],
            query: LogQuery(), now: Self.now, calendar: Self.utc
        )
        let rendered = LogRenderer().render(LogFrame(model: model, columns: 80), palette: colorOffPalette)
        Self.expectFits(rendered, 80)
        let row = rendered.first { $0.contains("✕ Stopped") } ?? ""
        #expect(row.hasSuffix("abc-def"))
        #expect(TerminalWidth.of("日本") == 4)
        #expect(TerminalWidth.of("e\u{301}") == 1)
        #expect(TerminalWidth.of("🚀") == 2)
        #expect(TerminalWidth.clip("日本語", to: 4) == "日…")
    }

    /// `lines` with each glyph's own ink taken out: what is left must
    /// carry no escape at all.
    static func outsideGlyphs(_ lines: [String], _ palette: Palette) -> String {
        var text = lines.joined(separator: "\n")
        for (glyph, ink) in [("✕", palette.deny), ("◐", palette.mark), ("→", palette.trace), ("◆", palette.heading)] {
            text = text.replacingOccurrences(of: ink + glyph + palette.reset, with: glyph)
        }
        return text
    }

    @Test("with color only the glyphs carry ink: ✕ red, ◐ amber, → blue, ◆ heading; every word plain")
    func colors() {
        let palette = Palette(for: ColorCapability(colorsEnabled: true))
        let rendered = Self.lines(LogQuery(all: true), palette: palette)
        let stopped = rendered.first { $0.contains("Stopped") } ?? ""
        let wouldStop = rendered.first { $0.contains("Would stop") } ?? ""
        #expect(stopped.contains(palette.deny + "✕" + palette.reset + " Stopped"))
        #expect(wouldStop.contains(palette.mark + "◐" + palette.reset + " Would stop"))
        #expect(rendered.contains { $0.contains(palette.trace + "→" + palette.reset + " rv log") } == false)
        #expect(rendered.contains { $0.contains(palette.heading + "◆" + palette.reset + " last 7 days") })
        #expect(Self.outsideGlyphs(rendered, palette).contains("\u{1B}") == false)
        // The → line, when there is one.
        let folded = Self.lines(palette: palette)
        #expect(folded.contains { $0.contains(palette.trace + "→" + palette.reset + " rv log --all") })
        #expect(Self.outsideGlyphs(folded, palette).contains("\u{1B}") == false)
        // No color: not one escape.
        #expect(Self.lines(palette: colorOffPalette).joined().contains("\u{1B}") == false)
    }

    @Test("a code is shown as text, and a row with none ends at its command")
    func codesAreFielded() {
        let model = LogViewModel(
            entries: [
                LogEntry(time: Self.at(14, 0), agent: "claude", stopped: true, rule: "core.git:reset-hard",
                         tool: "Bash", target: "", command: "git reset --hard", code: "\u{1B}c"),
                LogEntry(time: Self.at(13, 0), agent: "claude", stopped: true, rule: "core.git:reset-hard",
                         tool: "Bash", target: "", command: "git reset --hard", code: nil),
            ],
            query: LogQuery(), now: Self.now, calendar: Self.utc
        )
        let rendered = LogRenderer().render(LogFrame(model: model), palette: colorOffPalette)
        #expect(rendered.joined().contains("\u{1B}") == false)
        #expect(rendered.allSatisfy { $0.hasSuffix(" ") == false })
        #expect(rendered.contains { $0.hasSuffix("git reset --hard") })
    }

    @Test("terminal escapes in a cell are shown, not sent")
    func escapesFielded() {
        let model = LogViewModel(
            entries: [LogEntry(time: Self.at(14, 0), agent: "claude", stopped: true, rule: "core.git:reset-hard",
                               tool: "Read", target: "~/evil\u{1B}[2Jname", code: "abc-def")],
            query: LogQuery(), now: Self.now, calendar: Self.utc
        )
        let rendered = LogRenderer().render(LogFrame(model: model), palette: colorOffPalette).joined()
        #expect(rendered.contains("\u{1B}") == false)
    }

    @Test("clip keeps the width and ends in …")
    func clip() {
        #expect(TerminalWidth.clip("git reset --hard origin/main", to: 10) == "git reset…")
        #expect(TerminalWidth.clip("Bash", to: 10) == "Bash")
    }
}
