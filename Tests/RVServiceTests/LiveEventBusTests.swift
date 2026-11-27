import Foundation
import RVDomain
import RVIPC
import Synchronization
import Testing
@testable import RVService

/// The bus's own contract: cursors, the bounded ring, "missed N", resync,
/// long-poll waits, and that publishing never waits on a subscriber.
@Suite("Live event bus")
struct LiveEventBusTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func decision(_ n: Int) -> LiveEventPayload {
        .decision(LiveDecision(verdict: .allowed, host: .claude, tool: .bash, command: "echo \(n)"))
    }

    @Test func readsFromZeroInOrderAndCursorAdvances() {
        let bus = LiveEventBus(capacity: 8)
        for n in 1...3 { bus.publish(decision(n), at: t0) }
        let first = bus.read(after: 0, stream: nil)
        #expect(first.events.map(\.sequence) == [1, 2, 3])
        #expect(first.cursor == 3)
        #expect(first.missed == 0)
        #expect(first.resync == false)
        #expect(first.events.first?.atMs == 1_700_000_000_000)
        bus.publish(decision(4), at: t0)
        let second = bus.read(after: first.cursor, stream: first.stream)
        #expect(second.events.map(\.sequence) == [4])
    }

    @Test func firstReadWithoutCursorStartsAtTheHead() {
        let bus = LiveEventBus(capacity: 8)
        for n in 1...5 { bus.publish(decision(n), at: t0) }
        let reply = bus.read(after: nil, stream: nil)
        #expect(reply.events.isEmpty)
        #expect(reply.cursor == 5)
        #expect(reply.stream == bus.stream)
    }

    @Test func slowSubscriberLosesTheOldestAndIsToldHowMany() {
        let bus = LiveEventBus(capacity: 4)
        let start = bus.read(after: nil, stream: nil)
        for n in 1...10 { bus.publish(decision(n), at: t0) }
        let reply = bus.read(after: start.cursor, stream: start.stream)
        #expect(reply.missed == 6)
        #expect(reply.events.map(\.sequence) == [7, 8, 9, 10])
        #expect(reply.resync == false)
        // Caught up: nothing more, nothing missed.
        let next = bus.read(after: reply.cursor, stream: reply.stream)
        #expect(next.events.isEmpty && next.missed == 0)
    }

    @Test func batchesAreCappedAndResumeAtTheCursor() {
        let bus = LiveEventBus(capacity: 32)
        for n in 1...10 { bus.publish(decision(n), at: t0) }
        let first = bus.read(after: 0, stream: nil, limit: 4)
        #expect(first.events.map(\.sequence) == [1, 2, 3, 4])
        let second = bus.read(after: first.cursor, stream: first.stream, limit: 4)
        #expect(second.events.map(\.sequence) == [5, 6, 7, 8])
    }

    @Test func cursorFromAnotherStreamResyncsFromTheOldest() {
        let bus = LiveEventBus(capacity: 4)
        for n in 1...6 { bus.publish(decision(n), at: t0) }
        let reply = bus.read(after: 2, stream: UUID())
        #expect(reply.resync)
        #expect(reply.events.map(\.sequence) == [3, 4, 5, 6])
    }

    @Test func cursorPastTheHeadResyncs() {
        let bus = LiveEventBus(capacity: 4)
        bus.publish(decision(1), at: t0)
        let reply = bus.read(after: 99, stream: bus.stream)
        #expect(reply.resync)
        #expect(reply.events.map(\.sequence) == [1])
    }

    @Test func longPollWakesOnPublish() async {
        let bus = LiveEventBus(capacity: 8)
        let start = bus.read(after: nil, stream: nil)
        let poll = Task {
            await bus.next(after: start.cursor, stream: start.stream, wait: .seconds(30), wire: true)
        }
        try? await Task.sleep(for: .milliseconds(50))
        bus.publish(decision(1), at: t0)
        let reply = await poll.value
        #expect(reply.events.map(\.sequence) == [1])
    }

    @Test func longPollAnswersEmptyWhenTheWaitPasses() async {
        let bus = LiveEventBus(capacity: 8)
        let clock = ContinuousClock()
        let started = clock.now
        let reply = await bus.next(after: 0, stream: bus.stream, wait: .milliseconds(100), wire: true)
        #expect(reply.events.isEmpty)
        #expect(reply.cursor == 0)
        #expect(clock.now - started >= .milliseconds(90))
    }

    @Test func cancellingAPollEndsItsWait() async {
        let bus = LiveEventBus(capacity: 8)
        let poll = Task { await bus.next(after: 0, stream: bus.stream, wait: nil, wire: false) }
        try? await Task.sleep(for: .milliseconds(50))
        poll.cancel()
        let reply = await poll.value
        #expect(reply.events.isEmpty)
    }

    @Test func wirePollsPastTheCapAnswerAtOnce() async {
        let bus = LiveEventBus(capacity: 8)
        let parked = (0..<LiveEventBus.maxWireWaiters).map { _ in
            Task { await bus.next(after: 0, stream: bus.stream, wait: .seconds(30), wire: true) }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let started = clock.now
        let extra = await bus.next(after: 0, stream: bus.stream, wait: .seconds(30), wire: true)
        #expect(extra.events.isEmpty)
        #expect(clock.now - started < .seconds(2))
        bus.publish(decision(1), at: t0)
        for poll in parked {
            #expect(await poll.value.events.map(\.sequence) == [1])
        }
    }

    /// The acceptance property at the bus: subscribers that never read,
    /// and polls parked waiting, do not slow `publish`, and the ring stays
    /// bounded however far they fall behind.
    @Test func stuckSubscribersNeverSlowPublish() async {
        let bus = LiveEventBus(capacity: 64)
        // Subscribed, never iterated.
        let neverRead = bus.subscribe()
        let parked = (0..<LiveEventBus.maxWireWaiters).map { _ in
            Task { await bus.next(after: bus.head, stream: bus.stream, wait: .seconds(5), wire: true) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let started = clock.now
        for n in 0..<20_000 { bus.publish(decision(n), at: t0) }
        let elapsed = clock.now - started
        // 20k publishes is microseconds each; a publish that waited on any
        // subscriber would take seconds.
        #expect(elapsed < .seconds(2), "20k publishes took \(elapsed)")
        for poll in parked { _ = await poll.value }
        let tail = bus.read(after: 0, stream: bus.stream)
        #expect(tail.missed == 20_000 - 64)
        #expect(tail.events.count == 64)
        _ = neverRead
    }

    @Test func inProcessSubscriptionDeliversEventsAndMissedMarkers() async {
        let bus = LiveEventBus(capacity: 4)
        let subscription = bus.subscribe()
        for n in 1...6 { bus.publish(decision(n), at: t0) }
        var iterator = subscription.makeAsyncIterator()
        var seen: [LiveEventDelivery] = []
        for _ in 0..<5 {
            guard let next = await iterator.next() else { break }
            seen.append(next)
        }
        #expect(seen.first == .missed(2))
        let sequences = seen.compactMap { delivery -> UInt64? in
            if case .event(let event) = delivery { return event.sequence }
            return nil
        }
        #expect(sequences == [3, 4, 5, 6])
    }

    @Test func inProcessSubscriptionEndsWhenItsTaskIsCancelled() async {
        let bus = LiveEventBus(capacity: 4)
        let subscription = bus.subscribe()
        let reader = Task {
            var count = 0
            for await _ in subscription { count += 1 }
            return count
        }
        bus.publish(decision(1), at: t0)
        try? await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        #expect(await reader.value == 1)
    }

    /// A sink is the lossless path (the decision log): it sees every event
    /// in order however far a cursor reader would have fallen behind.
    @Test func sinksSeeEveryEventInOrderPastTheRing() throws {
        let bus = LiveEventBus(capacity: 4)
        let seen = SequenceLog()
        try bus.addSink { seen.append($0.sequence) }
        for n in 1...1_000 { bus.publish(decision(n), at: t0) }
        #expect(seen.values == Array(1...1_000))
        #expect(bus.read(after: 0, stream: bus.stream).missed == 996)
    }

    /// A sink added once the bus has published would start with a gap:
    /// it is refused, says how many it missed, and is never called.
    @Test func aSinkAfterTheFirstPublishIsRefused() {
        let bus = LiveEventBus(capacity: 4)
        bus.publish(decision(1), at: t0)
        bus.publish(decision(2), at: t0)
        let seen = SequenceLog()
        #expect(throws: LiveEventBus.SinkAfterPublish(missed: 2)) {
            try bus.addSink { seen.append($0.sequence) }
        }
        bus.publish(decision(3), at: t0)
        #expect(seen.values.isEmpty)
    }

    /// Events a reader may not see still move its cursor, and a batch with
    /// nothing visible keeps the poll waiting instead of answering empty.
    @Test func hiddenEventsMoveTheCursorAndThePollKeepsWaiting() async {
        let bus = LiveEventBus(capacity: 8)
        let onlyDecisions: @Sendable (LiveEvent) -> LiveEvent? = { event in
            if case .decision = event.payload { return event }
            return nil
        }
        let poll = Task {
            await bus.next(after: 0, stream: bus.stream, wait: .seconds(30), wire: true, visible: onlyDecisions)
        }
        try? await Task.sleep(for: .milliseconds(50))
        bus.publish(.unknown(kind: "proposal"), at: t0)
        try? await Task.sleep(for: .milliseconds(50))
        bus.publish(decision(2), at: t0)
        let reply = await poll.value
        #expect(reply.events.map(\.sequence) == [2])
        #expect(reply.cursor == 2)

        let hiddenOnly = await bus.next(
            after: 2, stream: bus.stream, wait: .milliseconds(50), wire: true, visible: onlyDecisions)
        #expect(hiddenOnly.events.isEmpty && hiddenOnly.cursor == 2)
        bus.publish(.unknown(kind: "proposal"), at: t0)
        let skipped = await bus.next(
            after: 2, stream: bus.stream, wait: .milliseconds(50), wire: true, visible: onlyDecisions)
        #expect(skipped.events.isEmpty)
        #expect(skipped.cursor == 3)
    }
}

private final class SequenceLog: Sendable {
    private let box = Mutex<[UInt64]>([])
    func append(_ value: UInt64) { box.withLock { $0.append(value) } }
    var values: [UInt64] { box.withLock { $0 } }
}
