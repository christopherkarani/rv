import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVTerm
import Testing
@testable import RVCLI

/// `rv term` over a real config folder: what it reads, and the frame it
/// draws from it. Never touches `~/.config/rv`.
@Suite("rv term")
struct TermCommandTests {
    static func fixture(now: Date) throws -> HomeDirectory {
        let home = try isolatedHome()
        let config = RVPolicyPaths.configDirectory(home: home)
        let log = DecisionLog(configDirectory: config)
        let rows: [(TimeInterval, DecisionVerdict, String, String?)] = [
            (-1_500, .allowed, "git status", nil),
            (-1_200, .allowed, "swift build", nil),
            (-600, .allowed, "rm -rf build", nil),
            (-300, .denied, "git reset --hard", "core.git:reset-hard"),
            (-20, .allowed, "ls -la", nil),
        ]
        for (offset, verdict, command, rule) in rows {
            #expect(log.append(DecisionRecord(
                time: now.addingTimeInterval(offset), verdict: verdict, host: .hook(.claude), tool: .bash,
                command: command, cwd: "~/src/rv", rule: rule, session: "s-1"), now: now))
        }
        // The would-stop the allowed `rm -rf build` was, and the deny.
        #expect(AuditLog.append(AuditEvent(
            time: now.addingTimeInterval(-600), kind: .commandObserved, decision: .allowed,
            subject: "core.filesystem:rm-rf", agent: "claude", source: "hook"), configDirectory: config))
        #expect(AuditLog.append(AuditEvent(
            time: now.addingTimeInterval(-300), kind: .commandDenied, decision: .denied,
            subject: "core.git:reset-hard", agent: "claude", source: "hook"), configDirectory: config))
        return home
    }

    static func text(_ lines: [TermLine]) -> [String] {
        lines.map { $0.map(\.text).joined() }
    }

    @Test func glanceFromARealFolder() throws {
        let now = Date()
        let home = try Self.fixture(now: now)
        var sources = TermSources(home: home)
        var state = TermState(now: now)
        sources.refresh(&state)
        let lines = Self.text(TermScreen.render(state, width: 80, height: 24))
        print(lines.joined(separator: "\n"))
        #expect(lines.count == 24)
        #expect(lines.allSatisfy { $0.count <= 80 })
        #expect(lines.contains { $0.contains("Nothing needs you.") })
        #expect(lines.contains { $0.contains("5 commands checked today  ·  1 stopped") })
        #expect(lines.contains { $0.contains("claude   ls -la   ✓") })
    }

    @Test func streamPairsTheWouldStopWithItsCommand() throws {
        let now = Date()
        let home = try Self.fixture(now: now)
        var sources = TermSources(home: home)
        var state = TermState(now: now, start: .stream)
        sources.refresh(&state)
        let lines = Self.text(TermScreen.render(state, width: 100, height: 24))
        print(lines.joined(separator: "\n"))
        #expect(lines.contains { $0.contains("◐  claude   rm -rf build") })
        #expect(state.rows.first { $0.text == "rm -rf build" }?.rule == "core.filesystem:rm-rf")
        #expect(lines.contains { $0.contains("✕") && $0.contains("git reset --hard") })
        #expect(lines.filter { $0.contains("git reset --hard") }.count == 1)
        #expect(!lines.contains { $0.contains("(command not logged)") })
    }

    @Test func aSecondRefreshReadsOnlyWhatIsNew() throws {
        let now = Date()
        let home = try Self.fixture(now: now)
        var sources = TermSources(home: home)
        var state = TermState(now: now)
        sources.refresh(&state)
        sources.refresh(&state)
        #expect(state.rows.count == 5)
        #expect(state.checkedToday == 5)
        #expect(state.tally.stoppedToday == 1)
    }

    @Test func noDecisionLogShowsNoCountRatherThanZero() throws {
        let home = try isolatedHome()
        var sources = TermSources(home: home)
        var state = TermState(now: Date(), start: .stream)
        sources.refresh(&state)
        #expect(state.checkedToday == nil)
        let lines = Self.text(TermScreen.render(state, width: 80, height: 24))
        #expect(lines.contains { $0.contains("keeps no decision log yet") })
    }

    @Test func keysDecode() {
        #expect(TermKey.decode([0x1B]) == [.input(.navigation(.escape))])
        #expect(TermKey.decode([0x1B, 0x5B, 0x5A]) == [.input(.navigation(.backTab))])
        #expect(TermKey.decode([0x1B, 0x5B, 0x41]) == [.input(.up)])
        #expect(TermKey.decode([0x1B, 0x5B, 0x44]) == [.input(.left)])
        #expect(TermKey.decode([0x1B, 0x5B, 0x31, 0x7E]) == [.other])
        #expect(TermKey.decode(Array("2 f?qjG".utf8)) == [
            .input(.navigation(.digit(2))), .input(.navigation(.space)), .input(.filter), .input(.keys), .input(.quit),
            .input(.down), .input(.startGuarding),
        ])
        #expect(TermKey.decode([0x0D]) == [.input(.enter)])
        #expect(TermKey.decode([0x03]) == [.exit])
        #expect(TermKey.decode([0x09]) == [.input(.navigation(.tab))])
    }

    @Test func paintedFramesStayPlainWithoutColour() {
        let frame: [TermLine] = [[TermSpan("✓ ", .ok), TermSpan("ran", .soft, bold: true)]]
        #expect(TermPaint.frame(frame, palette: .init(depth: .none), raw: false) == "✓ ran\n")
        let painted = TermPaint.frame(frame, palette: .init(depth: .truecolor), raw: true)
        #expect(painted.contains("\u{1B}[38;2;110;231;183m✓ \u{1B}[0m"))
        #expect(painted.contains("\u{1B}[1;38;2;185;185;195mran\u{1B}[0m"))
        #expect(painted.hasSuffix("\u{1B}[K"))
    }

    @Test func theCurrentTabAndTheModePillHaveABackground() {
        let tab: [TermLine] = [[TermSpan(" 1 Glance ", .fg, bold: true, fill: .sel)]]
        #expect(TermPaint.frame(tab, palette: .init(depth: .truecolor), raw: false)
            == "\u{1B}[1;38;2;236;236;241;48;2;31;29;51m 1 Glance \u{1B}[0m\n")
        #expect(TermPaint.frame(tab, palette: .init(depth: .ansi16), raw: false) == "\u{1B}[1;7m 1 Glance \u{1B}[0m\n")
        let faded: [TermLine] = [[TermSpan("x", .fg, faded: true)]]
        #expect(TermPaint.frame(faded, palette: .init(depth: .ansi16), raw: false) == "\u{1B}[2mx\u{1B}[0m\n")
    }
}
