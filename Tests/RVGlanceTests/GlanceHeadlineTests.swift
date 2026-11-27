import Foundation
import Testing
import RVDomain
@testable import RVGlance

/// The popover's first two lines for each state.
struct GlanceHeadlineTests {
    private func headline(_ glyph: GlanceGlyph) -> GlanceHeadline {
        GlanceHeadline(GlanceSamples.state(glyph), now: GlanceSamples.now, calendar: GlanceSamples.calendar)
    }

    @Test func everyStateHasItsWords() {
        #expect(headline(.guarding) == GlanceHeadline(title: "Guarding", subtitle: "2 agents · rvd healthy"))
        #expect(headline(.watching) == GlanceHeadline(title: "Watching", subtitle: "Codex in watch mode · rvd healthy"))
        #expect(headline(.needsYou) == GlanceHeadline(title: "Needs you", subtitle: "1 request · claude is waiting"))
        #expect(headline(.justStopped) == GlanceHeadline(title: "Just stopped", subtitle: "Claude Code · rvd healthy"))
        #expect(headline(.boxed) == GlanceHeadline(title: "Boxed", subtitle: "1 box running · rvd healthy"))
        #expect(headline(.paused) == GlanceHeadline(title: "Paused", subtitle: "back at 20:32 · rvd healthy"))
        #expect(headline(.notRunning) == GlanceHeadline(
            title: "rv isn't running", subtitle: "rvd stopped 2 min ago · agents are unguarded"))
        #expect(headline(.connecting) == GlanceHeadline(title: "Connecting to rvd", subtitle: "nothing is confirmed yet"))
    }

    @Test func aRvdThatNeverAnsweredHasNoStopTime() {
        var state = GlanceState(now: GlanceSamples.now, calendar: GlanceSamples.calendar)
        state.markDown("rvd isn't answering", at: GlanceSamples.now)
        #expect(state.downSince == nil)
        #expect(GlanceHeadline(state, now: GlanceSamples.now, calendar: GlanceSamples.calendar).subtitle
            == "rvd isn't answering · agents are unguarded")
    }

    @Test func requestsNameWhoIsWaiting() {
        var state = GlanceSamples.state(.needsYou)
        state.pending[ApprovalID(rawValue: "ask-2")] = .codex
        #expect(GlanceHeadline(state, now: GlanceSamples.now, calendar: GlanceSamples.calendar).subtitle
            == "2 requests · claude and codex are waiting")
        state.pending[ApprovalID(rawValue: "ask-3")] = .cursor
        #expect(GlanceHeadline(state, now: GlanceSamples.now, calendar: GlanceSamples.calendar).subtitle
            == "3 requests · 3 agents are waiting")
    }

    @Test func downTimeWords() {
        let now = GlanceSamples.now
        let calendar = GlanceSamples.calendar
        #expect(GlanceHeadline.ago(now.addingTimeInterval(-30), now: now, calendar: calendar) == "just now")
        #expect(GlanceHeadline.ago(now.addingTimeInterval(-150), now: now, calendar: calendar) == "2 min ago")
        #expect(GlanceHeadline.ago(now.addingTimeInterval(-7200), now: now, calendar: calendar) == "at 17:32")
    }

    @Test func anOldRvdIsNamed() {
        var state = GlanceSamples.state(.guarding)
        state.link = .liveWithoutEvents
        #expect(GlanceHeadline(state, now: GlanceSamples.now, calendar: GlanceSamples.calendar).subtitle
            == "2 agents · rvd is older than live events")
    }

    @Test func pluralsAndClock() {
        #expect(GlanceHeadline.plural(2, "box") == "2 boxes")
        #expect(GlanceHeadline.plural(1, "agent") == "1 agent")
        #expect(GlanceClock.ago(from: GlanceSamples.now, to: GlanceSamples.now.addingTimeInterval(59)) == "now")
        #expect(GlanceClock.ago(from: GlanceSamples.now, to: GlanceSamples.now.addingTimeInterval(7200)) == "2h")
    }
}
