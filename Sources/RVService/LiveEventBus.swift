import Foundation
import RVIPC
import Synchronization

/// rvd's live event bus (workstream I): decisions, asks and resolutions,
/// published once each and read by any number of subscribers.
///
/// One bounded ring holds the last `capacity` events, each numbered by a
/// sequence that starts at 1 for this bus's `stream`. A subscriber is only
/// a cursor into the ring, so a subscriber that is slow, stuck or gone
/// costs nothing: it falls behind, the ring drops the oldest events for
/// everyone, and its next read reports how many it lost (`missed`). There
/// is no per-subscriber queue to fill and no path from a subscriber back
/// to a publisher.
///
/// `publish` takes one short lock, writes one slot and wakes waiting
/// readers after the lock is released. It never awaits and never blocks on
/// a reader, which is what keeps it safe on the hook path.
package final class LiveEventBus: Sendable {
    /// Events kept for subscribers that fall behind.
    package static let defaultCapacity = 256
    /// Most events in one wire reply (bounds the frame).
    package static let maxBatch = 64
    /// Wire long polls allowed to wait at once. Each holds a transport
    /// connection (on Linux a thread and a slot under
    /// `UnixConnectionLimits.maxConnections`), so a flood of subscribers
    /// cannot crowd hooks out; a poll past the cap answers at once.
    package static let maxWireWaiters = 8

    /// This bus's sequence. A cursor from another stream (an earlier rvd)
    /// means nothing here.
    package let stream: UUID
    private let capacity: Int
    private let state: Mutex<State>

    private struct State {
        var slots: [LiveEvent?]
        var nextSequence: UInt64 = 1
        var waiters: [UUID: Waiter] = [:]

        var head: UInt64 { nextSequence - 1 }
    }

    private struct Waiter {
        enum Phase {
            /// Registered; the continuation is not installed yet.
            case armed
            case waiting(CheckedContinuation<Void, Never>)
            /// Woken (publish, timeout or cancel) before it started waiting.
            case fired
        }

        var phase: Phase
        /// Counts against `maxWireWaiters`.
        let wire: Bool
    }

    package init(capacity: Int = LiveEventBus.defaultCapacity, stream: UUID = UUID()) {
        self.capacity = max(1, capacity)
        self.stream = stream
        self.state = Mutex(State(slots: Array(repeating: nil, count: max(1, capacity))))
    }

    /// The last sequence published, 0 before the first.
    package var head: UInt64 { state.withLock { $0.head } }

    /// Publishes one event. O(1), never awaits, never blocks on a reader.
    package func publish(_ payload: LiveEventPayload, at time: Date) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let sequence = state.nextSequence
            state.slots[slot(of: sequence)] = LiveEvent(sequence: sequence, at: time, payload: payload)
            state.nextSequence = sequence + 1
            var woken: [CheckedContinuation<Void, Never>] = []
            for (id, waiter) in state.waiters {
                switch waiter.phase {
                case .waiting(let continuation):
                    woken.append(continuation)
                    state.waiters[id] = nil
                case .armed:
                    state.waiters[id]?.phase = .fired
                case .fired:
                    break
                }
            }
            return woken
        }
        for continuation in woken { continuation.resume() }
    }

    /// The events after `after` (oldest first, at most `limit`), without
    /// waiting. See `EventsParams` for the cursor rules.
    package func read(after: UInt64?, stream: UUID?, limit: Int = LiveEventBus.maxBatch) -> EventsReply {
        state.withLock { state in
            Self.page(of: state, capacity: capacity, busStream: self.stream, after: after, stream: stream,
                      limit: max(1, limit))
        }
    }

    /// `read`, or when nothing is ready, waits until an event is published,
    /// `wait` passes, or the task is cancelled, then reads again. Nil
    /// `wait` waits without a timeout (in-process subscribers only).
    /// `wire` polls count against `maxWireWaiters`; past it they answer
    /// at once.
    package func next(
        after: UInt64?, stream: UUID?, wait: Duration?, wire: Bool, limit: Int = LiveEventBus.maxBatch
    ) async -> EventsReply {
        let first = read(after: after, stream: stream, limit: limit)
        let nothingYet = first.events.isEmpty && first.missed == 0 && first.resync == false
        guard nothingYet, wait.map({ $0 > .zero }) ?? true else { return first }
        await waitForPublish(beyond: first.cursor, timeout: wait, wire: wire)
        return read(after: first.cursor, stream: self.stream, limit: limit)
    }

    /// An in-process subscription starting after the current head: every
    /// event published from now on, plus `.missed(n)` markers when this
    /// subscriber fell more than `capacity` events behind. Iterate it on
    /// your own task; cancelling that task ends the sequence.
    package func subscribe() -> LiveEventSubscription {
        LiveEventSubscription(bus: self, cursor: head)
    }

    // MARK: - Waiting

    private func waitForPublish(beyond cursor: UInt64, timeout: Duration?, wire: Bool) async {
        let id = UUID()
        let armed = state.withLock { state -> Bool in
            // Published since the read: no wait.
            guard state.head == cursor else { return false }
            if wire, state.waiters.values.filter(\.wire).count >= Self.maxWireWaiters { return false }
            state.waiters[id] = Waiter(phase: .armed, wire: wire)
            return true
        }
        guard armed else { return }
        let timer = timeout.map { timeout in
            Task { [weak self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                self?.wake(id)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    guard let waiter = state.waiters[id] else { return true }
                    if case .armed = waiter.phase {
                        state.waiters[id]?.phase = .waiting(continuation)
                        return false
                    }
                    state.waiters[id] = nil
                    return true
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            self.wake(id)
        }
        timer?.cancel()
        // A wake that lands after the wait ended finds nothing to resume;
        // drop the entry it may have marked `fired`.
        state.withLock { $0.waiters[id] = nil }
    }

    /// Ends one wait: resumes it, or marks it fired if it is not waiting yet.
    private func wake(_ id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiters[id] else { return nil }
            switch waiter.phase {
            case .waiting(let continuation):
                state.waiters[id] = nil
                return continuation
            case .armed:
                state.waiters[id]?.phase = .fired
                return nil
            case .fired:
                return nil
            }
        }
        continuation?.resume()
    }

    // MARK: - Pure paging

    private func slot(of sequence: UInt64) -> Int {
        Int(sequence % UInt64(capacity))
    }

    /// The reply for one read of `state`. A missing or foreign stream, or
    /// a cursor past the head, cannot be trusted: a cursor-less first read
    /// starts at the head; a foreign or impossible one restarts at the
    /// oldest retained event with `resync`.
    private static func page(
        of state: State, capacity: Int, busStream: UUID, after: UInt64?, stream: UUID?, limit: Int
    ) -> EventsReply {
        let head = state.head
        let oldest = head >= UInt64(capacity) ? head - UInt64(capacity) + 1 : 1
        let sameStream = stream == nil || stream == busStream
        var cursor: UInt64
        var resync = false
        if let after, sameStream, after <= head {
            // `after` without a stream reads "from this sequence", typically 0.
            cursor = after
        } else if after == nil, sameStream {
            return EventsReply(stream: busStream, cursor: head, events: [])
        } else {
            cursor = 0
            resync = true
        }
        let missed = cursor + 1 < oldest ? oldest - cursor - 1 : 0
        if missed > 0 { cursor = oldest - 1 }
        var events: [LiveEvent] = []
        var sequence = cursor + 1
        while sequence <= head, events.count < limit {
            if let event = state.slots[Int(sequence % UInt64(capacity))], event.sequence == sequence {
                events.append(event)
            }
            sequence += 1
        }
        let last = events.last?.sequence ?? cursor
        return EventsReply(stream: busStream, cursor: last, missed: missed, resync: resync, events: events)
    }
}

/// What an in-process subscriber receives.
package enum LiveEventDelivery: Sendable, Equatable {
    case event(LiveEvent)
    /// This many events were dropped before the next one: the subscriber
    /// fell behind the ring.
    case missed(UInt64)
}

/// An in-process subscriber: a cursor into a `LiveEventBus`. Ends when the
/// iterating task is cancelled.
package struct LiveEventSubscription: AsyncSequence, Sendable {
    package typealias Element = LiveEventDelivery

    let bus: LiveEventBus
    let cursor: UInt64

    package func makeAsyncIterator() -> Iterator {
        Iterator(bus: bus, cursor: cursor)
    }

    package struct Iterator: AsyncIteratorProtocol {
        let bus: LiveEventBus
        var cursor: UInt64
        var buffered: [LiveEventDelivery] = []

        package mutating func next() async -> LiveEventDelivery? {
            while buffered.isEmpty {
                if Task.isCancelled { return nil }
                let reply = await bus.next(after: cursor, stream: bus.stream, wait: nil, wire: false)
                if reply.missed > 0 { buffered.append(.missed(reply.missed)) }
                buffered += reply.events.map(LiveEventDelivery.event)
                cursor = reply.cursor
            }
            return buffered.removeFirst()
        }
    }
}
