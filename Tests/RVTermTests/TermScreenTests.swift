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

    static func text(_ state: TermState, width: Int = 80, height: Int = 24) -> [String] {
        TermScreen.render(state, width: width, height: height, calendar: calendar).map { $0.map(\.text).joined() }
    }

    @Test func calmGlanceSaysNothingNeedsYou() {
        var state = TermState(now: Self.now, calendar: Self.calendar)
        state.absorb(decisions: [Self.decision(-60, "git status")], now: Self.now, calendar: Self.calendar)
        let lines = Self.text(state)
        #expect(lines[3] == "  Nothing needs you.")
        #expect(lines[4] == "  rv is guarding. 1 command checked today, nothing stopped.")
        #expect(lines.allSatisfy { $0.count <= 80 })
        #expect(lines.count == 24)
    }

    @Test func anAskChangesTheSentenceAndShowsItsCard() {
        var state = TermState(now: Self.now, calendar: Self.calendar)
        state.asks = [TermAsk(agent: "claude", summary: "shared branch mutation in rv", since: Self.now.addingTimeInterval(-90))]
        let lines = Self.text(state)
        #expect(lines[3] == "  claude is asking you something.")
        #expect(lines.contains { $0.contains("⏺ claude wants to  shared branch mutation in rv  1m ago") })
        state.asks.append(state.asks[0])
        #expect(TermScreen.headline(state) == "2 requests need you.")
    }

    @Test func watchingSaysWhatGuardingWouldHaveStopped() {
        var state = TermState(now: Self.now, mode: .watching, calendar: Self.calendar)
        state.absorb(decisions: [Self.decision(-30, "rm -rf build")], now: Self.now, calendar: Self.calendar)
        state.absorb(audit: [AuditEvent(time: Self.now.addingTimeInterval(-30), kind: .commandObserved, decision: .allowed,
                                        subject: "core.filesystem:rm-rf", agent: "claude", source: "hook")],
                     now: Self.now, calendar: Self.calendar)
        #expect(Self.text(state)[4] == "  rv is watching. 1 command checked today; guarding would have stopped 1.")
        #expect(state.rows.map(\.event) == [.wouldStop])
        #expect(state.rows.first?.rule == "core.filesystem:rm-rf")
    }

    @Test func anAuditStopBeforeItsDecisionRowIsReplacedNotDoubled() {
        var state = TermState(now: Self.now, calendar: Self.calendar)
        state.absorb(audit: [AuditEvent(time: Self.now.addingTimeInterval(-5), kind: .commandDenied, decision: .denied,
                                        subject: "core.git:reset-hard", agent: "claude", source: "hook")],
                     now: Self.now, calendar: Self.calendar)
        #expect(state.rows.map(\.text) == ["(command not logged)"])
        state.absorb(decisions: [Self.decision(-5, "git reset --hard", .denied, rule: "core.git:reset-hard")],
                     now: Self.now, calendar: Self.calendar)
        #expect(state.rows.map(\.text) == ["git reset --hard"])
        #expect(state.rows.map(\.event) == [.stopped])
    }

    @Test func streamFilterKeepsOnlyWouldStopsAndStops() {
        var state = TermState(now: Self.now, start: .stream, calendar: Self.calendar)
        state.absorb(decisions: [
            Self.decision(-20, "ls"),
            Self.decision(-10, "git reset --hard", .denied, rule: "core.git:reset-hard"),
        ], now: Self.now, calendar: Self.calendar)
        state.wouldStopsOnly = true
        #expect(state.streamRows.map(\.text) == ["git reset --hard"])
        let lines = Self.text(state)
        #expect(lines.contains { $0.contains("✕ claude") && $0.contains("core.git:reset-hard") })
        #expect(!lines.contains { $0.contains(" ls ") })
    }

    @Test func tooSmallATerminalGetsANote() {
        let state = TermState(now: Self.now, calendar: Self.calendar)
        let lines = Self.text(state, width: 40, height: 10)
        #expect(lines.count == 10)
        #expect(lines[0].hasPrefix("rv term needs at least"))
    }

    @Test func theRiverMarksWhereThingsHappened() {
        var state = TermState(now: Self.now, calendar: Self.calendar)
        state.absorb(decisions: [
            Self.decision(-1_790, "old"),
            Self.decision(-1, "git reset --hard", .denied, rule: "core.git:reset-hard"),
        ], now: Self.now, calendar: Self.calendar)
        let river = TermScreen.river(state, cells: 60).map(\.text)
        #expect(river.count == 60)
        #expect(river.first == "•")
        #expect(river.last == "✕")
    }
}
