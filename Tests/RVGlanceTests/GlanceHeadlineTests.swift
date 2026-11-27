import Foundation
import Testing
@testable import RVGlance

/// The popover's first two lines for each state.
struct GlanceHeadlineTests {
    private func headline(_ glyph: GlanceGlyph) -> GlanceHeadline {
        GlanceHeadline(GlanceSamples.state(glyph), now: GlanceSamples.now, calendar: GlanceSamples.calendar)
    }

    @Test func everyStateHasItsWords() {
        #expect(headline(.guarding) == GlanceHeadline(title: "Guarding", subtitle: "2 agents · rvd healthy"))
        #expect(headline(.watching) == GlanceHeadline(title: "Watching", subtitle: "Codex in watch mode · rvd healthy"))
        #expect(headline(.needsYou) == GlanceHeadline(title: "Needs you", subtitle: "2 asks waiting · rvd healthy"))
        #expect(headline(.justStopped) == GlanceHeadline(title: "Just stopped", subtitle: "Claude Code · rvd healthy"))
        #expect(headline(.boxed) == GlanceHeadline(title: "Boxed", subtitle: "1 box running · rvd healthy"))
        #expect(headline(.paused) == GlanceHeadline(title: "Paused", subtitle: "back at 20:32 · rvd healthy"))
        #expect(headline(.notRunning) == GlanceHeadline(
            title: "rv isn't running", subtitle: "rvd isn't answering · agents are unguarded"))
    }

    @Test func connectingSaysSoInsteadOfDown() {
        let state = GlanceState(now: GlanceSamples.now, calendar: GlanceSamples.calendar)
        #expect(GlanceHeadline(state, now: GlanceSamples.now, calendar: GlanceSamples.calendar).title
            == "Connecting to rvd")
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
