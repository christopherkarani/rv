import Foundation
import RVHistory
import Testing
@testable import RVTerm

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
}()

/// 2026-11-22 14:00:00 UTC.
private let noon = Date(timeIntervalSince1970: 1_795_356_000)

private func event(
    _ kind: AuditEventKind, at time: Date, rule: String = "core.git:force-push", agent: String? = "claude-code",
    path: String? = nil
) -> AuditEvent {
    var detail: [String: String] = [:]
    if let path { detail["path"] = path }
    return AuditEvent(
        time: time, kind: kind, decision: kind == .commandDenied ? .denied : .info, subject: rule,
        agent: agent, source: "audit.jsonl", detail: detail
    )
}

@Test func tally_countsTodayByKind() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([
        event(.commandObserved, at: noon.addingTimeInterval(-60)),
        event(.commandObserved, at: noon.addingTimeInterval(-120)),
        event(.commandDenied, at: noon.addingTimeInterval(-30)),
        event(.secretMisuse, at: noon.addingTimeInterval(-10)),
        event(.egressDenied, at: noon.addingTimeInterval(-5)),
        event(.mcpCall, at: noon.addingTimeInterval(-1)),
    ], now: noon, calendar: utc)
    #expect(tally.watchedToday == 2)
    #expect(tally.stoppedToday == 1)
    #expect(tally.secretMisuseToday == 1)
    #expect(tally.egressDeniedToday == 1)
    #expect(tally.week.count == 3)
    #expect(tally.lastEventTime == noon.addingTimeInterval(-1))
}

@Test func tally_yesterdayIsInTheWeekButNotToday() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([event(.commandObserved, at: noon.addingTimeInterval(-20 * 3600))], now: noon, calendar: utc)
    #expect(tally.watchedToday == 0)
    #expect(tally.week.count == 1)
}

@Test func tally_dropsMarksOlderThanAWeek() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([
        event(.commandObserved, at: noon.addingTimeInterval(-TermTally.weekWindow - 1)),
        event(.commandObserved, at: noon.addingTimeInterval(-3600)),
    ], now: noon, calendar: utc)
    #expect(tally.week.count == 1)
    tally.advance(to: noon.addingTimeInterval(TermTally.weekWindow), calendar: utc)
    #expect(tally.week.isEmpty)
}

@Test func tally_marksKeepRuleAgentAndPathButNoCommand() {
    let mark = TermMark(event(.commandDenied, at: noon, rule: "core.fs:rm-outside", agent: nil, path: "~/Library"))
    #expect(mark == TermMark(time: noon, verdict: .stopped, rule: "core.fs:rm-outside", agent: nil, path: "~/Library"))
    #expect(TermMark(event(.mcpCall, at: noon)) == nil)
}

@Test func tally_riverIsTheLastHalfHourOldestFirst() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([
        event(.commandObserved, at: noon.addingTimeInterval(-60), rule: "b"),
        event(.commandObserved, at: noon.addingTimeInterval(-31 * 60), rule: "old"),
        event(.commandDenied, at: noon.addingTimeInterval(-600), rule: "a"),
    ], now: noon, calendar: utc)
    #expect(tally.river(now: noon).map(\.rule) == ["a", "b"])
}

@Test func tally_weekByRuleOrdersByCountThenRecency() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([
        event(.commandObserved, at: noon.addingTimeInterval(-300), rule: "push"),
        event(.commandObserved, at: noon.addingTimeInterval(-200), rule: "push"),
        event(.commandObserved, at: noon.addingTimeInterval(-100), rule: "reset"),
        event(.commandObserved, at: noon.addingTimeInterval(-50), rule: "curl"),
        event(.commandDenied, at: noon.addingTimeInterval(-10), rule: "push"),
    ], now: noon, calendar: utc)
    let watched = tally.weekByRule()
    #expect(watched.map(\.rule) == ["push", "curl", "reset"])
    #expect(watched.first?.count == 2)
    #expect(watched.first?.last == noon.addingTimeInterval(-200))
    #expect(tally.weekByRule(.stopped).map(\.rule) == ["push"])
}

@Test func tally_midnightStartsANewToday() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([event(.commandObserved, at: noon), event(.secretMisuse, at: noon)], now: noon, calendar: utc)
    #expect(tally.watchedToday == 1)
    let tomorrow = noon.addingTimeInterval(12 * 3600)
    tally.advance(to: tomorrow, calendar: utc)
    #expect(tally.dayStart == utc.startOfDay(for: tomorrow))
    #expect(tally.watchedToday == 0)
    #expect(tally.secretMisuseToday == 0)
    #expect(tally.week.count == 1)
}

@Test func tally_weekByDayHasSevenDaysEndingToday() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([
        event(.commandObserved, at: noon),
        event(.commandDenied, at: noon),
        event(.commandObserved, at: noon.addingTimeInterval(-2 * 86_400)),
    ], now: noon, calendar: utc)
    let days = tally.weekByDay(now: noon, calendar: utc)
    #expect(days.count == 7)
    #expect(days.last?.day == utc.startOfDay(for: noon))
    #expect(days.last?.watched == 1)
    #expect(days.last?.stopped == 1)
    #expect(days[4].watched == 1)
    #expect(days.map(\.watched).reduce(0, +) == 2)
}

@Test func tally_acceptsEventsOutOfOrder() {
    var tally = TermTally(now: noon, calendar: utc)
    tally.absorb([event(.commandObserved, at: noon.addingTimeInterval(-10), rule: "late")], now: noon, calendar: utc)
    tally.absorb([event(.commandObserved, at: noon.addingTimeInterval(-500), rule: "early")], now: noon, calendar: utc)
    #expect(tally.week.map(\.rule) == ["early", "late"])
    #expect(tally.lastEventTime == noon.addingTimeInterval(-10))
}
