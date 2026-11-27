import Foundation
import Testing
import RVDomain
@testable import RVGlance

/// Menu bar v5 etiquette: loud only for a question, one banner per agent,
/// silence for what already happened.
struct GlanceEtiquetteTests {
    private let now = GlanceSamples.now
    private var live: GlanceState {
        var state = GlanceSamples.state(.guarding)
        state.pending = [:]
        return state
    }

    private func with(_ asks: [String: HookHost], from base: GlanceState? = nil) -> GlanceState {
        var state = base ?? live
        state.pending = Dictionary(uniqueKeysWithValues: asks.map { (ApprovalID(rawValue: $0.key), $0.value) })
        return state
    }

    private func posts(_ actions: [GlanceNoticeAction]) -> [GlanceNotice] {
        actions.compactMap { if case .post(let notice) = $0 { notice } else { nil } }
    }

    @Test func anAgentsFirstAskIsTimeSensitive() {
        var etiquette = GlanceEtiquette()
        let actions = etiquette.plan(from: live, to: with(["a": .claude]), now: now)
        #expect(actions == [.post(GlanceNotice(
            id: "rv.ask.claude", thread: "rv.ask.claude", title: "claude needs you",
            body: "1 request is waiting in the menu bar", level: .timeSensitive))])
    }

    @Test func moreAsksWithinAMinuteUpdateTheOneBannerQuietly() {
        var etiquette = GlanceEtiquette()
        let one = with(["a": .claude])
        _ = etiquette.plan(from: live, to: one, now: now)
        let three = with(["a": .claude, "b": .claude, "c": .claude])
        let update = posts(etiquette.plan(from: one, to: three, now: now.addingTimeInterval(20)))
        #expect(update.map(\.id) == ["rv.ask.claude"])
        #expect(update.map(\.level) == [.passive])
        #expect(update.map(\.body) == ["3 from claude · answer in the menu bar"])

        let four = with(["a": .claude, "b": .claude, "c": .claude, "d": .claude])
        let later = posts(etiquette.plan(from: three, to: four, now: now.addingTimeInterval(61)))
        #expect(later.map(\.level) == [.timeSensitive])
    }

    @Test func eachAgentGetsItsOwnBanner() {
        var etiquette = GlanceEtiquette()
        let notices = posts(etiquette.plan(from: live, to: with(["a": .claude, "b": .codex]), now: now))
        #expect(notices.map(\.id) == ["rv.ask.claude", "rv.ask.codex"])
        #expect(notices.allSatisfy { $0.level == .timeSensitive })
    }

    @Test func anAnsweredAskTakesItsBannerAway() {
        var etiquette = GlanceEtiquette()
        let two = with(["a": .claude, "b": .claude])
        _ = etiquette.plan(from: live, to: two, now: now)
        let one = with(["b": .claude])
        #expect(posts(etiquette.plan(from: two, to: one, now: now)).map(\.level) == [.passive])
        #expect(etiquette.plan(from: one, to: live, now: now) == [.remove(["rv.ask.claude"])])
        #expect(etiquette.plan(from: live, to: live, now: now) == [])
    }

    @Test func whatAlreadyHappenedNeverNotifies() {
        var etiquette = GlanceEtiquette()
        let stopped = GlanceSamples.state(.justStopped)
        var watched = GlanceSamples.state(.watching)
        watched.today.stopped += 5
        #expect(etiquette.plan(from: live, to: stopped, now: now) == [])
        #expect(etiquette.plan(from: stopped, to: watched, now: now) == [])
    }

    @Test func rvdGoingDownIsTimeSensitiveAndClearsAsks() {
        var etiquette = GlanceEtiquette()
        let asking = with(["a": .claude])
        _ = etiquette.plan(from: live, to: asking, now: now)
        var down = asking
        down.markDown("rvd isn't answering", at: now)
        let actions = etiquette.plan(from: asking, to: down, now: now)
        #expect(actions.first == .remove(["rv.ask.claude"]))
        #expect(posts(actions).map(\.id) == [GlanceEtiquette.downID])
        #expect(posts(actions).map(\.level) == [.timeSensitive])
        #expect(posts(actions).first?.body == "Agents are unguarded · run rv doctor --fix")
        #expect(etiquette.plan(from: down, to: down, now: now) == [])
    }

    @Test func aFlappingRvdAlertsOnceThenQuietly() {
        var etiquette = GlanceEtiquette()
        var down = live
        down.markDown("gone", at: now)
        _ = etiquette.plan(from: live, to: down, now: now)
        #expect(etiquette.plan(from: down, to: live, now: now) == [.remove([GlanceEtiquette.downID])])
        let again = posts(etiquette.plan(from: live, to: down, now: now.addingTimeInterval(30)))
        #expect(again.map(\.level) == [.passive])
        let muchLater = posts(etiquette.plan(from: live, to: down, now: now.addingTimeInterval(400)))
        #expect(muchLater.map(\.level) == [.timeSensitive])
    }

    @Test func anAskThatSurvivesABlipComesBackQuietly() {
        var etiquette = GlanceEtiquette()
        let asking = with(["a": .claude])
        _ = etiquette.plan(from: live, to: asking, now: now)
        var down = asking
        down.markDown("gone", at: now)
        _ = etiquette.plan(from: asking, to: down, now: now)
        let back = etiquette.plan(from: down, to: asking, now: now.addingTimeInterval(120))
        #expect(back.first == .remove([GlanceEtiquette.downID]))
        #expect(posts(back).map(\.level) == [.passive])
    }

    @Test func connectingIsSilentAndStartupAsksAnnounce() {
        var etiquette = GlanceEtiquette()
        let connecting = GlanceState(now: now, calendar: GlanceSamples.calendar)
        #expect(etiquette.plan(from: connecting, to: connecting, now: now) == [])
        let first = posts(etiquette.plan(from: connecting, to: with(["a": .codex]), now: now))
        #expect(first.map(\.level) == [.timeSensitive])
    }

    @Test func rvdDownAtStartupStillSaysSo() {
        var etiquette = GlanceEtiquette()
        let connecting = GlanceState(now: now, calendar: GlanceSamples.calendar)
        var down = connecting
        down.markDown("rvd isn't answering", at: now)
        #expect(posts(etiquette.plan(from: connecting, to: down, now: now)).map(\.id) == [GlanceEtiquette.downID])
    }
}
