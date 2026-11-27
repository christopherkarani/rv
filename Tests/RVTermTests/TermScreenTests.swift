import Foundation
import RVHistory
import Testing
@testable import RVTerm

@Suite("rv term screen")
struct TermScreenTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func decision(_ offset: TimeInterval, _ command: String, _ verdict: DecisionVerdict = .allowed, rule: String? = nil) -> DecisionRecord {
        DecisionRecord(time: now.addingTimeInterval(offset), verdict: verdict, host: .hook(.claude), tool: .bash,
                       command: command, cwd: "~/src/rv", rule: rule)
    }

    static func observed(_ offset: TimeInterval, _ rule: String) -> AuditEvent {
        AuditEvent(time: now.addingTimeInterval(offset), kind: .commandObserved, decision: .allowed,
                   subject: rule, agent: "claude", source: "hook")
    }

    static func text(_ state: TermState, width: Int = 80, height: Int = 24) -> [String] {
        TermScreen.render(state, width: width, height: height, calendar: calendar).map { $0.map(\.text).joined() }
    }

    /// A watching day: three commands, one of them a would-stop.
    static func watchingDay() -> TermState {
        var state = TermState(now: now, mode: .watching, calendar: calendar)
        state.absorb(decisions: [
            decision(-600, "git status"),
            decision(-300, "git reset --hard HEAD~3"),
            decision(-60, "swift build"),
        ], now: now, calendar: calendar)
        state.absorb(audit: [observed(-300, "core.git:reset-hard")], now: now, calendar: calendar)
        return state
    }

    @Test func theTopRowHasTheTabsTheModeAndTheTime() {
        let lines = Self.text(Self.watchingDay())
        print(lines.joined(separator: "\n"))
        #expect(lines[0].hasPrefix("  ◆ rv"))
        #expect(lines[0].contains(" 1 Glance   2 Stream   3 Needs you "))
        #expect(lines[0].hasSuffix(" ◐ watching   08:00"))
        #expect(lines.count == 24)
        #expect(lines.allSatisfy { $0.count <= 80 })
    }

    @Test func calmGlanceIsOneCentredSentence() {
        let lines = Self.text(Self.watchingDay())
        let headline = lines.first { $0.contains("Nothing needs you.") }
        #expect(headline?.trimmingCharacters(in: .whitespaces) == "Nothing needs you.")
        #expect(headline.map { $0.prefix(while: { $0 == " " }).count } == (80 - 18) / 2)
        #expect(lines.contains { $0.contains("3 commands checked today  ·  1 would have been stopped") })
        #expect(lines.contains { $0.contains("1 agent working") })
        #expect(lines.contains { $0.contains("git reset --har… ◐") })
        #expect(lines.contains { $0.contains("30 min ago") && $0.hasSuffix("now ●") })
        #expect(lines.contains { $0.contains("claude   swift build   ✓") })
        #expect(lines.contains { $0.contains("◐ Ready to guard   rv would have stopped 1 command this week") })
        #expect(lines[23].contains("space stream   G start guarding   ? keys"))
    }

    @Test func theRiverIsBrailleWithABaseline() {
        let lines = Self.text(Self.watchingDay())
        let river = lines.filter { $0.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) } }
        #expect(river.count >= 1)
        #expect(river.last.map { $0.trimmingCharacters(in: .whitespaces).count } == 72)
    }

    @Test func anAskChangesTheSentenceAndShowsItsCard() {
        var state = TermState(now: Self.now, calendar: Self.calendar)
        state.asks = [TermAsk(agent: "claude", summary: "asks for: shared branch mutation", since: Self.now.addingTimeInterval(-90),
                              detail: "in rv")]
        let lines = Self.text(state)
        print(lines.joined(separator: "\n"))
        #expect(lines.contains { $0.contains("⏺ claude is asking you something.") })
        #expect(lines.contains { $0.contains("⏺ claude asks for: shared branch mutation") })
        #expect(lines.contains { $0.contains("in rv · asked 1m ago") })
        #expect(lines.contains { $0.contains("a  Allow once      d  Deny") })
        #expect(lines[0].contains("3 Needs you 1"))
        #expect(lines[23].contains("a allow   d deny   3 all requests"))
    }

    @Test func aFreshWouldStopTakesTheHeadline() {
        var state = TermState(now: Self.now, mode: .watching, calendar: Self.calendar)
        state.absorb(decisions: [Self.decision(-3, "rm -rf build")], now: Self.now, calendar: Self.calendar)
        state.absorb(audit: [Self.observed(-3, "core.filesystem:rm-rf")], now: Self.now, calendar: Self.calendar)
        let lines = Self.text(state)
        #expect(lines.contains { $0.contains("◐ claude tried something risky. rv let it run and noted it.") })
        #expect(lines.contains { $0.contains("rm -rf build   ⏎ why") })
        #expect(state.rows.map(\.event) == [.wouldStop])
        #expect(state.rows.first?.rule == "core.filesystem:rm-rf")
        var why = state
        let pressed96 = why.press(.enter, width: 80)
        #expect(pressed96)
        #expect(why.sheet == .why(rowID: state.rows[0].id))
        let sheet = Self.text(why)
        #expect(sheet.contains { $0.contains("◐  Would stop") })
        #expect(sheet.contains { $0.contains("core.filesystem:rm-rf") })
    }

    @Test func anAuditStopBeforeItsDecisionRowIsReplacedNotDoubled() {
        var state = TermState(now: Self.now, calendar: Self.calendar)
        state.absorb(audit: [AuditEvent(time: Self.now.addingTimeInterval(-5), kind: .commandDenied, decision: .denied,
                                        subject: "core.git:reset-hard", agent: "claude", source: "hook")],
                     now: Self.now, calendar: Self.calendar)
        #expect(state.rows.map(\.text) == [TermRow.notLogged])
        #expect(state.rows.map(\.display) == ["core.git:reset-hard"])
        state.absorb(decisions: [Self.decision(-5, "git reset --hard", .denied, rule: "core.git:reset-hard")],
                     now: Self.now, calendar: Self.calendar)
        #expect(state.rows.map(\.text) == ["git reset --hard"])
        #expect(state.rows.map(\.event) == [.stopped])
    }

    @Test func streamIsNewestFirstWithTheSelectionAndTheFilter() {
        var state = Self.watchingDay()
        state.navigation.open(.stream)
        var lines = Self.text(state)
        print(lines.joined(separator: "\n"))
        #expect(lines[2].hasPrefix("  All agents  live ●"))
        #expect(lines[2].hasSuffix(" everything   ◐ would stop"))
        #expect(lines[4].trimmingCharacters(in: .whitespaces) == "07:59  ·  claude   swift build")
        #expect(lines[5] == "  07:55  ◐  claude   git reset --hard HEAD~3")
        #expect(lines[6] == "  07:50  ·  claude   git status")
        #expect(lines[23].contains("↑↓ move   ⏎ why   f would-stops only   esc back   ? keys"))
        let pressed127 = state.press(.down, width: 80)
        #expect(pressed127)
        #expect(state.selectedIndex == 1)
        let pressed129 = state.press(.filter, width: 80)
        #expect(pressed129)
        #expect(state.streamRows.map(\.text) == ["git reset --hard HEAD~3"])
        lines = Self.text(state)
        #expect(!lines.contains { $0.contains("git status") })
        #expect(lines[23].contains("f everything"))
    }

    @Test func aWideStreamShowsAgentsAndTheSelectedRow() {
        var state = Self.watchingDay()
        state.navigation.open(.stream)
        state.press(.down, width: 150)
        let lines = Self.text(state, width: 150, height: 30)
        print(lines.joined(separator: "\n"))
        #expect(lines[2].hasPrefix("  Agents"))
        #expect(lines[4].hasPrefix("   All agents"))
        #expect(lines[7].hasPrefix("   claude"))
        #expect(lines[8].hasPrefix("   rv"))
        #expect(lines.contains { $0.contains("◐  Would stop") })
        #expect(lines.contains { $0.contains("Guarding would") })
        state.press(.left, width: 150)
        state.press(.down, width: 150)
        #expect(state.agentFilter == "claude")
    }

    @Test func needsYouIsCalmWhenEmpty() {
        var state = TermState(now: Self.now, start: .needsYou, calendar: Self.calendar)
        state.tick(Self.now)
        let lines = Self.text(state)
        #expect(lines.contains { $0.contains("✓  Nothing needs you.") })
        #expect(lines[23].contains("esc back   ? keys"))
    }

    @Test func keysAreASheetOverTheView() {
        var state = Self.watchingDay()
        let pressed163 = state.press(.keys, width: 80)
        #expect(pressed163)
        let lines = Self.text(state)
        #expect(lines.contains { $0.contains("│  Keys") })
        #expect(lines.contains { $0.contains("│  1  2  3   Glance, Stream, Needs you") })
        let pressed167 = state.press(.quit, width: 80)
        #expect(pressed167)
        #expect(state.sheet == nil)
        let pressed169 = state.press(.quit, width: 80)
        #expect(!pressed169)
    }

    @Test func startGuardingSaysItComesNext() {
        var state = Self.watchingDay()
        state.press(.startGuarding, width: 80)
        #expect(Self.text(state).contains { $0.contains("Starting guarding from rv term comes next.") })
        state.tick(Self.now.addingTimeInterval(5))
        #expect(state.message == nil)
    }

    @Test func tooSmallATerminalGetsANote() {
        let state = TermState(now: Self.now, calendar: Self.calendar)
        let lines = Self.text(state, width: 40, height: 10)
        #expect(lines.count == 10)
        #expect(lines[0].hasPrefix("rv term needs at least"))
    }

    @Test func numbersGetCommas() {
        #expect(TermScreen.format(1_284) == "1,284")
        #expect(TermScreen.format(999) == "999")
        #expect(TermScreen.format(1_000_000) == "1,000,000")
    }
}
