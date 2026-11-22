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
                 tool: "Bash", target: "", code: "a7c-835"),
        LogEntry(time: at(13, 58), agent: "claude", stopped: false, rule: "core.judge:laya-block", isJudge: true,
                 tool: "Bash", target: "", code: "0d1-4e2"),
        LogEntry(time: at(13, 47), agent: "codex", stopped: false, rule: "core.git:push-force-long",
                 tool: "Bash", target: "", code: "b20-7de"),
        LogEntry(time: at(13, 31), agent: "claude", stopped: false, rule: "core.judge:laya-block", isJudge: true,
                 tool: "Bash", target: "", code: "5f3-c19"),
        LogEntry(time: at(12, 15), agent: "cursor", stopped: true, rule: "core.secrets:id-ed25519",
                 tool: "Read", target: "~/.ssh/id_ed25519", code: "e41-0b7"),
        LogEntry(time: at(11, 20), agent: "claude", stopped: false, rule: "core.filesystem:rm-rf-general",
                 tool: "Bash", target: "", code: "9ac-2f0"),
        LogEntry(time: at(10, 5), agent: "claude", stopped: false, rule: "core.judge:laya-block", isJudge: true,
                 tool: "Bash", target: "", code: "77e-a01"),
        LogEntry(time: at(9, 12, daysAgo: 1), agent: "codex", stopped: false, wouldAsk: true, rule: "core.secrets:env",
                 tool: "Edit", target: "~/code/app/Sources/Payments/Internal/.env.production", code: "c08-d3a"),
    ]

    static func lines(_ query: LogQuery = LogQuery(), columns: Int = 80, palette: Palette = colorOffPalette) -> [String] {
        let model = LogViewModel(entries: fixture, query: query, now: now, calendar: utc)
        return LogRenderer().render(LogFrame(model: model, columns: columns), palette: palette)
    }

    @Test("80 columns, no color: fixed columns, judge notes folded, one summary line")
    func goldenAt80() {
        let rendered = Self.lines()
        for line in rendered {
            #expect(line.count <= 80, "\(line.count): \(line)")
            #expect(line.hasSuffix(" ") == false, "trailing space: \(line)")
        }
        #expect(rendered.joined(separator: "\n") == Self.golden80)
    }

    static let golden80 = """

          ◆ last 7 days                                                                5

          14:02  claude  ✕ Stopped     core.git:reset-hard            Bash       a7c-835
          13:47  codex   ◐ Would stop  core.git:push-force-long       Bash       b20-7de
          12:15  cursor  ✕ Stopped     core.secrets:id-ed25519        …_ed25519  e41-0b7
          11:20  claude  ◐ Would stop  core.filesystem:rm-rf-general  Bash       9ac-2f0
          Sat 21 Nov
          09:12  codex   ◐ Would stop  core.secrets:env               …oduction  c08-d3a

          2 stopped · 3 would stop · judge: 3 notes in shadow, hidden

          → rv log --all   every row, judge notes too
        """

    @Test("120 columns: the whole command fits, and a file keeps the end of its path")
    func goldenAt120() {
        let rendered = Self.lines(columns: 120)
        #expect(rendered.contains("  12:15  cursor  ✕ Stopped     core.secrets:id-ed25519        Read ~/.ssh/id_ed25519                             e41-0b7"))
        #expect(rendered.contains("  09:12  codex   ◐ Would stop  core.secrets:env               Edit …p/Sources/Payments/Internal/.env.production  c08-d3a"))
    }

    @Test("rows stay one line each at any width; the command ends in … when cut")
    func narrowAndWide() {
        for columns in [60, 80, 120, 200] {
            let rendered = Self.lines(LogQuery(all: true), columns: columns)
            let rows = rendered.filter { $0.contains("Stopped") || $0.contains("Would stop") }
            #expect(rows.count == Self.fixture.count)
            if columns >= 80 {
                #expect(rendered.allSatisfy { $0.count <= columns }, "\(columns)")
            }
        }
        let narrow = Self.lines(columns: 80).joined(separator: "\n")
        #expect(narrow.contains("…"))
        let wide = Self.lines(columns: 200).joined(separator: "\n")
        #expect(wide.contains("Edit ~/code/app/Sources/Payments/Internal/.env.production"))
    }

    @Test("with color, a stop is red and a would-stop amber; the words stay")
    func colors() {
        let palette = Palette(for: ColorCapability(colorsEnabled: true))
        let rendered = Self.lines(palette: palette)
        let stopped = rendered.first { $0.contains("✕ Stopped") } ?? ""
        let wouldStop = rendered.first { $0.contains("◐ Would stop") } ?? ""
        #expect(stopped.contains(palette.deny + "✕ Stopped"))
        #expect(wouldStop.contains(palette.mark + "◐ Would stop"))
        #expect(wouldStop.contains(palette.deny) == false)
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
        #expect(LogRenderer.clip("git reset --hard origin/main", to: 10) == "git reset…")
        #expect(LogRenderer.clip("Bash", to: 10) == "Bash")
    }
}
