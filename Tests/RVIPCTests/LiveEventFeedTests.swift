import Foundation
import Synchronization
import Testing
import RVDomain
@testable import RVIPC

/// `LiveEventFeed` against a scripted rvd: cursor, reconnect, skew,
/// backpressure and cancellation, with a clock the test controls.
struct LiveEventFeedTests {
    private let first = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let second = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!

    private func decision(_ sequence: UInt64, _ command: String = "git status") -> LiveEvent {
        LiveEvent(sequence: sequence, atMs: 1_700_000_000_000 + Int64(sequence),
                  payload: .decision(LiveDecision(verdict: .allowed, host: .claude, tool: .bash, command: command)))
    }

    private func feed(
        _ source: ScriptedPolls, start: LiveFeedStart = .now, clock: TestClock = TestClock()
    ) -> LiveEventFeed<ScriptedPolls> {
        LiveEventFeed(source: source, start: start, pacing: LiveFeedPacing(), clock: clock.feedClock)
    }

    /// Reads `count` updates (fewer if the feed ends first).
    private func take(_ count: Int, from feed: LiveEventFeed<ScriptedPolls>) async -> [LiveFeedUpdate] {
        var updates: [LiveFeedUpdate] = []
        var iterator = feed.makeAsyncIterator()
        while updates.count < count, let update = await iterator.next() { updates.append(update) }
        return updates
    }

    @Test func eventsArriveInOrderAndTheCursorIsEchoed() async {
        let source = ScriptedPolls([
            .reply(EventsReply(stream: first, cursor: 2, events: [decision(1), decision(2)])),
            .reply(EventsReply(stream: first, cursor: 3, events: [decision(3)])),
        ])
        let updates = await take(4, from: feed(source))
        #expect(updates == [.link(.live), .event(decision(1)), .event(decision(2)), .event(decision(3))])
        let params = source.params
        #expect(params.first == EventsParams(stream: nil, after: nil, waitMs: EventsParams.maxWaitMs))
        #expect(params.dropFirst().first == EventsParams(stream: first, after: 2, waitMs: EventsParams.maxWaitMs))
    }

    @Test func oldestRetainedStartsAtZero() async {
        let source = ScriptedPolls([.reply(EventsReply(stream: first, cursor: 1, events: [decision(1)]))])
        _ = await take(2, from: feed(source, start: .oldestRetained))
        #expect(source.params.first?.after == 0)
        #expect(source.params.first?.stream == nil)
    }

    /// `missed` and `resync` come before the events they precede; the
    /// first reply's resync is not news (the reader just started).
    @Test func missedAndResyncPrecedeTheirEvents() async {
        let source = ScriptedPolls([
            .reply(EventsReply(stream: first, cursor: 1, resync: true, events: [decision(1)])),
            .reply(EventsReply(stream: first, cursor: 9, missed: 7, events: [decision(9)])),
            .reply(EventsReply(stream: second, cursor: 1, resync: true, events: [decision(1, "ls")])),
        ])
        let updates = await take(6, from: feed(source))
        #expect(updates == [
            .link(.live), .event(decision(1)),
            .missed(7), .event(decision(9)),
            .resync, .event(decision(1, "ls")),
        ])
    }

    /// A duplicated or replayed reply never delivers an event twice, and
    /// never moves the cursor back.
    @Test func aReplayedReplyRepeatsNothing() async {
        let reply = EventsReply(stream: first, cursor: 2, events: [decision(1), decision(2)])
        let source = ScriptedPolls([
            .reply(reply), .reply(reply),
            .reply(EventsReply(stream: first, cursor: 3, events: [decision(2), decision(3)])),
        ])
        let updates = await take(4, from: feed(source))
        #expect(updates == [.link(.live), .event(decision(1)), .event(decision(2)), .event(decision(3))])
        #expect(source.params.map(\.after) == [nil, 2, 2])
    }

    /// rvd down: one `down`, backoff that doubles to its cap, then `live`
    /// and the restarted rvd's resync. The old cursor is still offered.
    @Test func reconnectsWithBackoffAfterRvdGoesAway() async {
        let clock = TestClock()
        let source = ScriptedPolls(
            [.reply(EventsReply(stream: first, cursor: 4, events: [decision(4)]))]
                + Array(repeating: .failed("connect"), count: 7)
                + [.reply(EventsReply(stream: second, cursor: 1, resync: true, events: [decision(1)]))])
        let updates = await take(6, from: feed(source, clock: clock))
        #expect(updates == [
            .link(.live), .event(decision(4)),
            .link(.down("connect")),
            .link(.live), .resync, .event(decision(1)),
        ])
        #expect(clock.sleeps == [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
        ])
        #expect(source.params.last == EventsParams(stream: first, after: 4, waitMs: EventsParams.maxWaitMs))
    }

    /// An rvd from before `events`: reported once, asked again later, and
    /// a newer rvd that replaces it is picked up.
    @Test func anOldRvdIsUnsupportedThenUpgraded() async {
        let clock = TestClock()
        let source = ScriptedPolls([
            .unsupported, .unsupported,
            .reply(EventsReply(stream: first, cursor: 1, events: [decision(1)])),
        ])
        let updates = await take(3, from: feed(source, clock: clock))
        #expect(updates == [.link(.unsupported), .link(.live), .event(decision(1))])
        #expect(clock.sleeps == [.seconds(30), .seconds(30)])
    }

    @Test func aSkewedHelloIsAskedAgainLater() async {
        let clock = TestClock()
        let source = ScriptedPolls([
            .skewed, .failed("reset"), .skewed,
            .reply(EventsReply(stream: first, cursor: 0, events: [])),
        ])
        let updates = await take(4, from: feed(source, clock: clock))
        #expect(updates == [.link(.skewed), .link(.down("reset")), .link(.skewed), .link(.live)])
        #expect(clock.sleeps == [.seconds(30), .milliseconds(250), .seconds(30)])
    }

    @Test func aNonOwnerFeedEnds() async {
        let source = ScriptedPolls([.refused, .reply(EventsReply(stream: first, cursor: 1, events: [decision(1)]))])
        let updates = await take(10, from: feed(source))
        #expect(updates == [.link(.refused)])
        #expect(source.params.count == 1)
    }

    /// An empty reply that came at once (rvd at its waiter cap) pauses
    /// before the next poll; one that waited the full wait does not.
    @Test func anEarlyEmptyReplyPausesInsteadOfSpinning() async {
        let clock = TestClock()
        let empty = LiveEventsPollResult.reply(EventsReply(stream: first, cursor: 0, events: []))
        let source = ScriptedPolls([empty, empty, .reply(EventsReply(stream: first, cursor: 1, events: [decision(1)]))],
                                   pollTakes: [.zero, .seconds(5), .zero], clock: clock)
        _ = await take(2, from: feed(source, clock: clock))
        #expect(clock.sleeps == [.seconds(1)])
        #expect(source.params.count == 3)
    }

    /// Backpressure: the feed polls only when its reader asks. A reader
    /// that stops reading leaves rvd alone; rvd's ring answers for it.
    @Test func aSlowReaderMakesNoPollsAhead() async {
        let source = ScriptedPolls([
            .reply(EventsReply(stream: first, cursor: 3, events: [decision(1), decision(2), decision(3)])),
            .reply(EventsReply(stream: first, cursor: 4, events: [decision(4)])),
        ])
        var iterator = feed(source).makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(source.params.count == 1)
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(source.params.count == 1)
        _ = await iterator.next()
        #expect(source.params.count == 2)
    }

    /// Cancelling the reader ends the feed at once, even while rvd holds
    /// the poll open.
    @Test func cancellingMidPollEndsTheFeedAtOnce() async {
        let source = ScriptedPolls([], hangWhenEmpty: true)
        let reader = Task { await take(1, from: feed(source)) }
        while source.params.isEmpty { await Task.yield() }
        let started = ContinuousClock.now
        reader.cancel()
        let updates = await reader.value
        #expect(updates.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
        source.releaseHung()
    }

    @Test func cancellingDuringABackoffEndsTheFeed() async {
        let clock = TestClock(sleepsForReal: true)
        let source = ScriptedPolls([.failed("connect")])
        let reader = Task { await take(3, from: feed(source, clock: clock)) }
        while clock.sleeps.isEmpty { await Task.yield() }
        reader.cancel()
        #expect(await reader.value == [.link(.down("connect"))])
        #expect(source.params.count == 1)
    }

    @Test func aCancelledReaderNeverPolls() async {
        let source = ScriptedPolls([.reply(EventsReply(stream: first, cursor: 1, events: [decision(1)]))])
        let reader = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await take(1, from: feed(source))
        }
        #expect(await reader.value.isEmpty)
        #expect(source.params.isEmpty)
    }

    @Test func backoffDoublesToItsCap() {
        let pacing = LiveFeedPacing(firstBackoff: .milliseconds(100), maxBackoff: .milliseconds(700))
        #expect((1...6).map { pacing.backoff(attempt: $0) } == [
            .milliseconds(100), .milliseconds(200), .milliseconds(400),
            .milliseconds(700), .milliseconds(700), .milliseconds(700),
        ])
    }

    /// The state machine alone: an unknown event kind still moves the
    /// cursor (the open set of `LiveEventPayload`).
    @Test func anUnknownKindIsDeliveredAndMovesTheCursor() {
        var reader = LiveFeedReader(start: .now, pacing: LiveFeedPacing())
        #expect(reader.nextStep() == .poll(EventsParams(waitMs: EventsParams.maxWaitMs)))
        let unknown = LiveEvent(sequence: 5, atMs: 0, payload: .unknown(kind: "proposal"))
        reader.absorb(.reply(EventsReply(stream: first, cursor: 5, events: [unknown])), elapsed: .seconds(5))
        #expect(reader.nextStep() == .deliver(.link(.live)))
        #expect(reader.nextStep() == .deliver(.event(unknown)))
        #expect(reader.nextStep() == .poll(EventsParams(stream: first, after: 5, waitMs: EventsParams.maxWaitMs)))
    }
}

// MARK: - Doubles

/// A test clock: `now` advances only by what polls and sleeps take; sleeps
/// are recorded and return at once unless `sleepsForReal`.
private final class TestClock: Sendable {
    private let state = Mutex<(now: Duration, sleeps: [Duration])>((.zero, []))
    private let sleepsForReal: Bool

    init(sleepsForReal: Bool = false) {
        self.sleepsForReal = sleepsForReal
    }

    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func advance(_ by: Duration) {
        state.withLock { $0.now += by }
    }

    var feedClock: LiveFeedClock {
        LiveFeedClock(
            now: { self.state.withLock { $0.now } },
            sleep: { delay in
                self.state.withLock {
                    $0.sleeps.append(delay)
                    $0.now += delay
                }
                if self.sleepsForReal {
                    try await Task.sleep(for: .seconds(60))
                } else {
                    try Task.checkCancellation()
                }
            })
    }
}

/// rvd's answers, served in order. With the script used up it answers
/// `refused` (which ends the feed), or parks the poll until released
/// (`hangWhenEmpty`).
private final class ScriptedPolls: LiveEventsPolling, Sendable {
    private let state: Mutex<(script: [LiveEventsPollResult], takes: [Duration], seen: [EventsParams])>
    private let hangWhenEmpty: Bool
    private let clock: TestClock?
    private let hung = Mutex<[CheckedContinuation<Void, Never>]>([])

    init(_ script: [LiveEventsPollResult], pollTakes: [Duration] = [], clock: TestClock? = nil,
         hangWhenEmpty: Bool = false) {
        state = Mutex((script, pollTakes, []))
        self.hangWhenEmpty = hangWhenEmpty
        self.clock = clock
    }

    var params: [EventsParams] { state.withLock { $0.seen } }

    func releaseHung() {
        let parked = hung.withLock { parked in
            defer { parked.removeAll() }
            return parked
        }
        for continuation in parked { continuation.resume() }
    }

    func pollLiveEvents(_ params: EventsParams) async -> LiveEventsPollResult {
        let (next, take) = state.withLock { state -> (LiveEventsPollResult?, Duration) in
            state.seen.append(params)
            let take = state.takes.isEmpty ? Duration.seconds(5) : state.takes.removeFirst()
            return (state.script.isEmpty ? nil : state.script.removeFirst(), take)
        }
        clock?.advance(take)
        if let next { return next }
        if hangWhenEmpty {
            await withCheckedContinuation { continuation in hung.withLock { $0.append(continuation) } }
        }
        return .refused
    }
}
