import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
@testable import RVGlance

/// What Siri, Shortcuts and Focus can reach: a status sentence from one
/// read, and a freeze that only ever makes rv stricter.
struct GlanceIntentTests {
    private let stream = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - Stricter only

    @Test func theOnlyActionIntentsMayRequestIsFreeze() {
        #expect(GlanceStricterAction.allCases == [.freeze])
    }

    @Test(arguments: [false, true], GlanceFocusTransition.allCases)
    func theFocusPlannerFreezesOnlyOnAStartTheUserAskedFor(_ freezeOnStart: Bool, _ transition: GlanceFocusTransition) {
        let actions = GlanceFocusPlanner.actions(for: GlanceFocusFilter(freezeOnStart: freezeOnStart), on: transition)
        let expected: [GlanceStricterAction] = freezeOnStart && transition == .started ? [.freeze] : []
        #expect(actions == expected)
    }

    @Test func aFocusFilterIsOffByDefault() {
        #expect(GlanceFocusFilter().freezeOnStart == false)
        #expect(GlanceFocusPlanner.actions(for: GlanceFocusFilter(), on: .started).isEmpty)
    }

    @Test func endingAFocusNeverReachesTheFreezeControl() async {
        let control = RecordingFreeze()
        let services = GlanceIntentServices(reader: nil, freeze: control)
        #expect(await services.focusChanged(GlanceFocusFilter(freezeOnStart: true), .ended).isEmpty)
        #expect(await services.focusChanged(GlanceFocusFilter(freezeOnStart: false), .started).isEmpty)
        #expect(control.origins.isEmpty)
        let outcomes = await services.focusChanged(GlanceFocusFilter(freezeOnStart: true), .started)
        #expect(outcomes == [.alreadyFrozen])
        #expect(control.origins == [.focus])
    }

    // MARK: - Freeze outcomes

    @Test func theDefaultControlSaysRvdCannotFreezeYet() async {
        let outcome = await GlanceIntentServices.unconnected.freezeAll(origin: .intent)
        #expect(outcome == .unavailable(UnavailableFreezeControl.reason))
        #expect(outcome.dialog(calendar: GlanceSamples.calendar)
            == "rv can't freeze yet — rvd doesn't expose a freeze command.")
    }

    @Test func everyOutcomeIsSaidHonestly() {
        let calendar = GlanceSamples.calendar
        #expect(GlanceFreezeOutcome.frozen(count: 3, at: GlanceSamples.now).dialog(calendar: calendar)
            == "Froze 3 agents at 19:32 · nothing killed. Thaw them in rv.")
        #expect(GlanceFreezeOutcome.alreadyFrozen.dialog(calendar: calendar)
            == "Agents are already frozen. Thaw them in rv.")
        #expect(GlanceFreezeOutcome.failed("rvd isn't answering").dialog(calendar: calendar)
            == "rv couldn't freeze agents — rvd isn't answering.")
    }

    // MARK: - Status sentence

    @Test func everyStateHasOneSentence() {
        let today = "412 commands checked, 3 stopped today"
        #expect(sentence(.guarding) == "rv is guarding · 2 agents · \(today)")
        #expect(sentence(.watching) == "rv is watching · Codex in watch mode · \(today)")
        #expect(sentence(.needsYou) == "rv needs you · 2 asks waiting · \(today)")
        #expect(sentence(.justStopped)
            == "rv just stopped a command · Claude Code · 412 commands checked, 4 stopped today")
        #expect(sentence(.boxed) == "rv is guarding a box · 1 box running · \(today)")
        #expect(sentence(.paused) == "rv is paused · back at 20:32 · \(today)")
        #expect(sentence(.notRunning) == "rv isn't running — agents are unguarded")
    }

    @Test func connectingAndOldRvdAreSaidAsSuch() {
        let fresh = GlanceState(now: GlanceSamples.now, calendar: GlanceSamples.calendar)
        #expect(GlanceStatusSentence.make(fresh, now: GlanceSamples.now, calendar: GlanceSamples.calendar)
            == "rv is connecting to rvd — nothing is confirmed yet")
        var old = GlanceSamples.state(.guarding)
        old.link = .liveWithoutEvents
        #expect(GlanceStatusSentence.make(old, now: GlanceSamples.now, calendar: GlanceSamples.calendar)
            == "rv is guarding · 2 agents · rvd is older than live events")
    }

    // MARK: - One-shot read

    @Test func aStatusReadAsksForTheAsksThenOneEventsPollWithoutWaiting() async {
        let wire = FakeWire { method in
            switch method {
            case .pendingList: .pendingList(PendingListReply(generation: 1, items: [GlanceFeedTests.item("ask-1")]))
            default: .events(EventsReply(stream: stream, cursor: 7, events: [GlanceFeedTests.denied(7)]))
            }
        }
        let services = GlanceIntentServices(reader: GlanceReader(wire: wire), calendar: GlanceSamples.calendar)
        let said = await services.statusSentence(now: GlanceSamples.now)
        #expect(said == "rv needs you · 1 ask waiting · 1 command checked, 1 stopped today")
        guard wire.methods.count == 2, case .pendingList = wire.methods[0],
              case .events(let params) = wire.methods[1]
        else {
            Issue.record("expected pendingList then events, got \(wire.methods)")
            return
        }
        #expect(params == EventsParams(after: 0, waitMs: 0))
    }

    @Test func aStatusReadOfADeadRvdSaysAgentsAreUnguarded() async {
        let wire = FakeWire(dead: true) { _ in .pendingList(PendingListReply(generation: 0, items: [])) }
        let state = await GlanceReader(wire: wire).status(now: GlanceSamples.now, calendar: GlanceSamples.calendar)
        #expect(state.link == .down("rvd isn't answering"))
        #expect(wire.methods.isEmpty)
        #expect(GlanceStatusSentence.make(state, now: GlanceSamples.now, calendar: GlanceSamples.calendar)
            == "rv isn't running — agents are unguarded")
    }

    @Test func aStatusReadOfAnOldRvdKeepsTheAsks() async {
        let wire = FakeWire { method in
            if case .pendingList = method {
                return .pendingList(PendingListReply(generation: 1, items: [GlanceFeedTests.item("ask-9")]))
            }
            return .error(.unknownMethod)
        }
        let state = await GlanceReader(wire: wire).status(now: GlanceSamples.now, calendar: GlanceSamples.calendar)
        #expect(state.link == .liveWithoutEvents)
        #expect(state.pending == [ApprovalID(rawValue: "ask-9")])
    }

    @Test func withoutAReaderStatusSaysItIsNotConnected() async {
        #expect(await GlanceIntentServices.unconnected.statusSentence(now: GlanceSamples.now)
            == GlanceIntentServices.notConnected)
    }

    private func sentence(_ glyph: GlanceGlyph) -> String {
        GlanceStatusSentence.make(GlanceSamples.state(glyph), now: GlanceSamples.now, calendar: GlanceSamples.calendar)
    }
}

/// Records each freeze request and answers `alreadyFrozen`.
private final class RecordingFreeze: GlanceFreezeControl {
    private let log = Mutex<[GlanceFreezeOrigin]>([])

    var origins: [GlanceFreezeOrigin] { log.withLock { $0 } }

    func freezeAll(origin: GlanceFreezeOrigin) async -> GlanceFreezeOutcome {
        log.withLock { $0.append(origin) }
        return .alreadyFrozen
    }
}
