import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVGlance

/// The seven glyph states, today's numbers, the agent rows and the last
/// stop, folded from rvd's live events.
struct GlanceStateTests {
    private let now = GlanceSamples.now
    private let calendar = GlanceSamples.calendar
    private let stream = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test(arguments: GlanceGlyph.allCases)
    func eachSampleShowsItsGlyph(_ glyph: GlanceGlyph) {
        #expect(GlanceSamples.state(glyph).glyph(at: now) == glyph)
    }

    @Test func connectingIsNeitherGuardingNorDown() {
        let state = GlanceState(now: now, calendar: calendar)
        #expect(state.glyph(at: now) == .connecting)
    }

    @Test func downOutranksAQuestion() {
        var state = GlanceSamples.state(.needsYou)
        state.markDown("gone", at: now)
        #expect(state.glyph(at: now) == .notRunning)
        #expect(state.pending.isEmpty)
        #expect(state.downSince == now)
    }

    @Test func downSinceKeepsTheFirstFailureAndClearsWhenBack() {
        var state = GlanceSamples.state(.guarding)
        state.markDown("gone", at: now)
        state.markDown("still gone", at: now.addingTimeInterval(30))
        #expect(state.downSince == now)
        state.link = .live
        #expect(state.downSince == nil)
    }

    @Test func aQuestionOutranksAStopAndWatchMode() {
        var state = GlanceSamples.state(.justStopped)
        state.posture = .watching([])
        state.pending = [ApprovalID(rawValue: "a"): .claude]
        #expect(state.glyph(at: now) == .needsYou)
    }

    @Test func theStopFlashEndsAfterOneAndAHalfSeconds() {
        let state = GlanceSamples.state(.justStopped)
        #expect(state.glyph(at: now.addingTimeInterval(1.4)) == .justStopped)
        #expect(state.glyph(at: now.addingTimeInterval(1.5)) == .guarding)
    }

    @Test func aPauseThatEndedIsGuardingAgain() {
        let state = GlanceSamples.state(.paused)
        #expect(state.glyph(at: now.addingTimeInterval(3601)) == .guarding)
    }

    @Test func onlyAQuestionAndAStopAreTinted_onlyAQuestionBreathes() {
        #expect(GlanceGlyph.allCases.filter(\.isTinted) == [.needsYou, .justStopped])
        #expect(GlanceGlyph.allCases.filter(\.breathes) == [.needsYou])
    }

    @Test func eventsFoldIntoTodayAgentsAndTheLastStop() {
        var state = GlanceState(now: now, calendar: calendar)
        state.apply(reply([
            decision(.allowed, .claude, "swift build", secondsAgo: 30),
            decision(.denied, .claude, "git reset --hard", rule: "core.git:reset-hard", secondsAgo: 20),
            decision(.refused, .codex, "rm -rf ~/", rule: "rv.timeout", secondsAgo: 10),
            decision(.allowed, .claude, "git status", secondsAgo: 5),
        ]), now: now, calendar: calendar)

        #expect(state.link == .live)
        #expect(state.today.checked == 4)
        #expect(state.today.stopped == 2)
        #expect(state.lastStop == GlanceStop(
            host: .codex, action: "rm -rf ~/", rule: "rv.timeout", at: now.addingTimeInterval(-10)))
        #expect(state.recentAgents.map(\.host) == [.claude, .codex])
        #expect(state.agents[.claude]?.lastAction == "git status")
        #expect(state.agents[.claude]?.checkedToday == 3)
    }

    @Test func yesterdaysEventsMoveAgentsButNotTodaysNumbers() {
        var state = GlanceState(now: now, calendar: calendar)
        state.apply(reply([
            decision(.denied, .claude, "git clean -fdx", rule: "core.git:clean", secondsAgo: 86_400),
        ]), now: now, calendar: calendar)
        #expect(state.today.checked == 0)
        #expect(state.today.stopped == 0)
        #expect(state.lastStop == nil)
        #expect(state.agents[.claude]?.lastAction == "git clean -fdx")
    }

    @Test func midnightStartsTheCountsOver() {
        var state = GlanceSamples.state(.guarding)
        state.roll(to: now.addingTimeInterval(6 * 3600), calendar: calendar)
        #expect(state.today.checked == 0)
        #expect(state.agents.values.allSatisfy { $0.checkedToday == 0 })
        #expect(state.lastStop != nil)
    }

    @Test func anAskWaitsUntilItsResolution() {
        var state = GlanceState(now: now, calendar: calendar)
        let id = ApprovalID(rawValue: "ask-1")
        state.apply(reply([ask(id)]), now: now, calendar: calendar)
        #expect(state.glyph(at: now) == .needsYou)
        #expect(state.today.asked == 1)
        state.apply(reply([
            LiveEvent(sequence: 2, atMs: ms(now), payload: .resolution(
                LiveResolution(id: id, host: .claude, outcome: .allowOnce))),
        ]), now: now, calendar: calendar)
        #expect(state.pending.isEmpty)
        #expect(state.glyph(at: now) == .guarding)
    }

    @Test func unknownEventsAndMissedCountsAreKept() {
        var state = GlanceState(now: now, calendar: calendar)
        state.apply(EventsReply(stream: stream, cursor: 9, missed: 3, events: [
            LiveEvent(sequence: 9, atMs: ms(now), payload: .unknown(kind: "box")),
        ]), now: now, calendar: calendar)
        #expect(state.missed == 3)
        #expect(state.today == GlanceToday(day: calendar.startOfDay(for: now)))
    }

    @Test func idleAgentsSayHowLong() {
        let state = GlanceSamples.state(.guarding)
        #expect(state.agents[.cursor]?.idleLabel(at: now) == "idle 14m")
        #expect(state.agents[.claude]?.idleLabel(at: now) == nil)
        #expect(state.activeAgentCount(at: now) == 2)
    }

    @Test func postureReadsGuardHostsAndTheMachineMode() {
        #expect(GlancePosture(configJSON: nil) == .guarding)
        #expect(GlancePosture(configJSON: Data("not json".utf8)) == .guarding)
        #expect(GlancePosture(configJSON: Data(#"{"guard":{"hosts":{"claude":"block"}}}"#.utf8)) == .guarding)
        #expect(GlancePosture(configJSON: Data(#"{"guard":{"hosts":{"codex":"observe","claude":"observe"}}}"#.utf8))
            == .watching([.claude, .codex]))
        #expect(GlancePosture(configJSON: Data(#"{"guard":{"mode":"observe"}}"#.utf8)) == .watching([]))
        // An open `rv pause` outranks the stored modes; an ended one does not.
        let from = Date(timeIntervalSince1970: 1_764_252_720)
        let paused = GuardConfig(hosts: [.claude: .block], pause: GuardWindow(from: from, until: from.addingTimeInterval(600)))
        #expect(GlancePosture(config: paused, now: from.addingTimeInterval(1)) == .paused(until: from.addingTimeInterval(600)))
        #expect(GlancePosture(config: paused, now: from.addingTimeInterval(600)) == .guarding)
        var state = GlanceState(today: GlanceToday(day: from))
        state.link = .live
        state.posture = .paused(until: from.addingTimeInterval(600))
        #expect(state.glyph(at: from.addingTimeInterval(1)) == .paused)
        #expect(state.pauseEnd == from.addingTimeInterval(600))
        #expect(state.glyph(at: from.addingTimeInterval(600)) == .guarding)
    }

    // MARK: - Helpers

    private func reply(_ events: [LiveEvent]) -> EventsReply {
        EventsReply(stream: stream, cursor: events.last?.sequence ?? 0, events: events)
    }

    private func decision(
        _ verdict: LiveVerdict, _ host: HookHost, _ command: String, rule: String? = nil, secondsAgo: TimeInterval
    ) -> LiveEvent {
        LiveEvent(
            sequence: UInt64(1_000_000 - secondsAgo), atMs: ms(now.addingTimeInterval(-secondsAgo)),
            payload: .decision(LiveDecision(verdict: verdict, host: host, tool: .bash, command: command, rule: rule)))
    }

    private func ask(_ id: ApprovalID) -> LiveEvent {
        LiveEvent(sequence: 1, atMs: ms(now), payload: .ask(LiveAsk(item: PendingListItem(
            id: id, host: .claude, folder: "rv", actionKind: "git push",
            fingerprint: ActionFingerprint(rawValue: "shell:git"),
            identity: ApprovalIdentity(session: SessionID(validating: "sess")!, agent: .claude)))))
    }

    private func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
