import Foundation
import Synchronization

// Live events, client side (workstream I, chunk I2): one async sequence over
// rvd's `events` long poll (`sdk/WIRE.md` §4.7) that the CLI, rv term and
// rv.app share. It keeps the cursor, reconnects after rvd goes away, tells
// an old or skewed rvd apart from a down one, and stops at once when the
// reading task is cancelled.
//
// The sequence is pulled: it polls only when its reader asks for the next
// update, and holds at most one reply. A reader that falls behind costs rvd
// nothing (rvd's ring drops the oldest events and the next reply says
// `missed N`), so a slow subscriber can never slow a hook decision.

/// What one `events` poll came back with, as a feed needs it. Each client
/// (the CLI's `ServiceClient`, rv.app's XPC bridge) maps its own transport
/// errors onto these.
public enum LiveEventsPollResult: Sendable, Equatable {
    case reply(EventsReply)
    /// The rvd answering predates `events`. Not a failure: keep showing
    /// what the caller read before (files, `pendingWatch`) and ask again
    /// later, since a newer rvd may replace it.
    case unsupported
    /// rvd refused this client's hello (protocol or major-version skew, or
    /// rvd has no core packs). Asked again later, like `unsupported`.
    case skewed
    /// rvd answered `authorizationDenied`: this caller is not rvd's owner.
    /// Final: the feed ends.
    case refused
    /// rvd could not be reached, or the reply was unusable. Retried with
    /// backoff.
    case failed(String)
}

/// Something that can make one `events` poll.
public protocol LiveEventsPolling: Sendable {
    func pollLiveEvents(_ params: EventsParams) async -> LiveEventsPollResult
}

/// Where the feed's connection to rvd stands. Reported once per change.
public enum LiveFeedLink: Sendable, Equatable {
    /// rvd answered a poll; events flow.
    case live
    /// rvd predates live events; the feed asks again every `retryLater`.
    case unsupported
    /// rvd refused the hello; the feed asks again every `retryLater`.
    case skewed
    /// rvd is unreachable; the feed retries with backoff. The reason is
    /// the first failure's, for logs (not for screens).
    case down(String)
    /// rvd says this caller is not its owner. The feed ends after this.
    case refused
}

/// One thing the feed tells its reader, in the order rvd sent it.
public enum LiveFeedUpdate: Sendable, Equatable {
    case link(LiveFeedLink)
    /// The reader fell behind rvd's ring and this many events were dropped
    /// before the next one ("missed N").
    case missed(UInt64)
    /// rvd restarted (or did not know the cursor): an unknown number of
    /// events are gone. Reload state built from earlier events
    /// (`pendingList`) before applying the next ones.
    case resync
    case event(LiveEvent)
}

/// The feed's timings. Defaults follow `sdk/WIRE.md` §4.7.
public struct LiveFeedPacing: Sendable {
    /// `waitMs` on each poll (rvd caps it at `EventsParams.maxWaitMs`).
    public var waitMs: Int
    /// Pause after an empty reply that came back well before `waitMs`
    /// (rvd at its waiter cap), so the feed never spins.
    public var busyPause: Duration
    /// First retry after rvd is unreachable; doubles up to `maxBackoff`.
    public var firstBackoff: Duration
    public var maxBackoff: Duration
    /// How often an unsupported or skewed rvd is asked again.
    public var retryLater: Duration

    public init(
        waitMs: Int = EventsParams.maxWaitMs,
        busyPause: Duration = .seconds(1),
        firstBackoff: Duration = .milliseconds(250),
        maxBackoff: Duration = .seconds(5),
        retryLater: Duration = .seconds(30)
    ) {
        self.waitMs = waitMs
        self.busyPause = busyPause
        self.firstBackoff = firstBackoff
        self.maxBackoff = maxBackoff
        self.retryLater = retryLater
    }

    /// Backoff before the `attempt`th retry in a row (1-based).
    func backoff(attempt: Int) -> Duration {
        var delay = firstBackoff
        var step = 1
        while step < attempt, delay < maxBackoff {
            delay *= 2
            step += 1
        }
        return min(delay, maxBackoff)
    }
}

/// Where a new feed starts reading.
public enum LiveFeedStart: Sendable, Equatable {
    /// At rvd's live head: only events published from now on.
    case now
    /// At the oldest event rvd still holds (its ring of the last 256).
    case oldestRetained
}

/// Live events from rvd as an async sequence of `LiveFeedUpdate`s.
///
/// ```swift
/// for await update in LiveEventFeed(source: client) {
///     switch update {
///     case .event(let event): model.apply(event)
///     case .resync: model.reload()
///     case .missed(let count): model.noteMissed(count)
///     case .link(let link): model.show(link)
///     }
/// }
/// ```
///
/// The loop ends when the reading task is cancelled (at once, even mid
/// poll) or after `.link(.refused)`. It never throws.
public struct LiveEventFeed<Source: LiveEventsPolling>: AsyncSequence, Sendable {
    public typealias Element = LiveFeedUpdate

    let source: Source
    let start: LiveFeedStart
    let pacing: LiveFeedPacing
    let clock: LiveFeedClock

    public init(source: Source, start: LiveFeedStart = .now, pacing: LiveFeedPacing = LiveFeedPacing()) {
        self.init(source: source, start: start, pacing: pacing, clock: .continuous)
    }

    /// Test seam: a clock whose sleeps and readings the test controls.
    package init(source: Source, start: LiveFeedStart, pacing: LiveFeedPacing, clock: LiveFeedClock) {
        self.source = source
        self.start = start
        self.pacing = pacing
        self.clock = clock
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(feed: self)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let feed: LiveEventFeed
        private var reader: LiveFeedReader

        init(feed: LiveEventFeed) {
            self.feed = feed
            self.reader = LiveFeedReader(start: feed.start, pacing: feed.pacing)
        }

        public mutating func next() async -> LiveFeedUpdate? {
            while true {
                switch reader.nextStep() {
                case .deliver(let update):
                    return update
                case .finish:
                    return nil
                case .pause(let delay):
                    guard (try? await feed.clock.sleep(delay)) != nil, !Task.isCancelled else {
                        reader.finish()
                        return nil
                    }
                case .poll(let params):
                    guard !Task.isCancelled else {
                        reader.finish()
                        return nil
                    }
                    let started = feed.clock.now()
                    guard let result = await LiveFeedPoll.run(params, on: feed.source) else {
                        reader.finish()
                        return nil
                    }
                    reader.absorb(result, elapsed: feed.clock.now() - started)
                }
            }
        }
    }
}

/// Sleeps and elapsed time for a feed. `now` is any monotonic reading.
package struct LiveFeedClock: Sendable {
    package var now: @Sendable () -> Duration
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    static var continuous: LiveFeedClock {
        let clock = ContinuousClock()
        let origin = clock.now
        return LiveFeedClock(
            now: { clock.now - origin },
            sleep: { try await clock.sleep(for: $0) })
    }
}

/// The feed's state machine, free of I/O and time: what to do next, and
/// how a poll's result changes the cursor and the link.
package struct LiveFeedReader: Sendable {
    package enum Step: Sendable, Equatable {
        case deliver(LiveFeedUpdate)
        case poll(EventsParams)
        case pause(Duration)
        case finish
    }

    private let pacing: LiveFeedPacing
    private var stream: UUID?
    private var cursor: UInt64?
    private var queued: [LiveFeedUpdate] = []
    private var pause: Duration?
    private var link: LiveFeedLink?
    private var failuresInARow = 0
    private var finished = false

    package init(start: LiveFeedStart, pacing: LiveFeedPacing) {
        self.pacing = pacing
        self.cursor = start == .oldestRetained ? 0 : nil
    }

    package mutating func nextStep() -> Step {
        if !queued.isEmpty { return .deliver(queued.removeFirst()) }
        if finished { return .finish }
        if let pause {
            self.pause = nil
            return .pause(pause)
        }
        return .poll(EventsParams(stream: stream, after: cursor, waitMs: pacing.waitMs))
    }

    package mutating func finish() {
        finished = true
        queued.removeAll()
    }

    /// Folds one poll's result in. `elapsed` is how long the poll took.
    package mutating func absorb(_ result: LiveEventsPollResult, elapsed: Duration) {
        switch result {
        case .reply(let reply):
            failuresInARow = 0
            report(.live)
            absorb(reply, elapsed: elapsed)
        case .unsupported:
            failuresInARow = 0
            report(.unsupported)
            pause = pacing.retryLater
        case .skewed:
            failuresInARow = 0
            report(.skewed)
            pause = pacing.retryLater
        case .refused:
            report(.refused)
            finished = true
        case .failed(let reason):
            failuresInARow += 1
            if case .down = link {} else { report(.down(reason)) }
            pause = pacing.backoff(attempt: failuresInARow)
        }
    }

    private mutating func absorb(_ reply: EventsReply, elapsed: Duration) {
        let sameStream = stream == reply.stream
        // A first call (no stream yet) asked for this start; anything else
        // with resync set lost events.
        if reply.resync, stream != nil { queued.append(.resync) }
        if reply.missed > 0 { queued.append(.missed(reply.missed)) }
        // An event at or before the cursor on the same stream was already
        // delivered: a duplicated or replayed reply never repeats one.
        let floor = sameStream ? cursor ?? 0 : 0
        var last = floor
        for event in reply.events where !sameStream || event.sequence > floor {
            queued.append(.event(event))
            last = max(last, event.sequence)
        }
        stream = reply.stream
        // Never move the cursor backwards on one stream.
        cursor = sameStream ? max(reply.cursor, last, floor) : max(reply.cursor, last)
        if reply.events.isEmpty, pacing.waitMs <= 0 || elapsed < .milliseconds(pacing.waitMs / 2) {
            pause = pacing.busyPause
        }
    }

    private mutating func report(_ next: LiveFeedLink) {
        guard link != next else { return }
        link = next
        queued.append(.link(next))
    }
}

/// One poll that a cancelled reader stops waiting on. The poll itself runs
/// on to its own deadline (`waitMs` plus the transport margin), then its
/// reply is dropped; the cursor lives in the reader, so nothing is lost.
enum LiveFeedPoll {
    static func run<Source: LiveEventsPolling>(
        _ params: EventsParams, on source: Source
    ) async -> LiveEventsPollResult? {
        let once = LiveFeedOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LiveEventsPollResult?, Never>) in
                guard once.arm(continuation) else { return }
                Task {
                    once.resume(with: await source.pollLiveEvents(params))
                }
            }
        } onCancel: {
            once.resume(with: nil)
        }
    }
}

/// Resumes one continuation once, whichever of the poll and cancellation
/// comes first. Cancellation may land before the continuation is armed.
private final class LiveFeedOnce: Sendable {
    private enum State {
        case idle
        case armed(CheckedContinuation<LiveEventsPollResult?, Never>)
        case cancelledEarly
        case done
    }

    private let state = Mutex(State.idle)

    /// False when cancellation already came; the continuation is resumed.
    func arm(_ continuation: CheckedContinuation<LiveEventsPollResult?, Never>) -> Bool {
        let early = state.withLock { state -> Bool in
            if case .cancelledEarly = state {
                state = .done
                return true
            }
            state = .armed(continuation)
            return false
        }
        if early { continuation.resume(returning: nil) }
        return !early
    }

    func resume(with result: LiveEventsPollResult?) {
        let taken = state.withLock { state -> CheckedContinuation<LiveEventsPollResult?, Never>? in
            switch state {
            case .armed(let continuation):
                state = .done
                return continuation
            case .idle:
                if result == nil { state = .cancelledEarly }
                return nil
            case .cancelledEarly, .done:
                return nil
            }
        }
        taken?.resume(returning: result)
    }
}
