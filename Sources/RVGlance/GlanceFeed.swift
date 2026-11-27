import Foundation
import RVIPC

/// Drives the menu bar: long-polls rvd's live events, keeps the cursor,
/// reloads the asks when rvd restarts, and backs off while rvd is down.
/// A value the polling task owns: `step` advances it, `run` loops until
/// the task is cancelled.
public struct GlanceFeed: Sendable {
    /// How long one poll may park in rvd.
    public static let pollWaitMs = EventsParams.maxWaitMs
    /// First wait after rvd stops answering; doubles up to `maxBackoff`.
    public static let firstBackoff: Duration = .seconds(2)
    public static let maxBackoff: Duration = .seconds(30)
    /// How often to re-read the asks when rvd has no `events`.
    public static let pendingPollInterval: Duration = .seconds(5)
    /// An empty reply sooner than this means rvd is at its waiter cap.
    static let emptyReplyFloor: TimeInterval = 0.5

    private let reader: GlanceReader
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let posture: @Sendable () -> GlancePosture
    public private(set) var state: GlanceState
    private var stream: UUID?
    private var cursor: UInt64?
    private var needsPending = true
    private var backoff: Duration = GlanceFeed.firstBackoff

    public init(
        reader: GlanceReader,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        posture: @escaping @Sendable () -> GlancePosture = { .guarding }
    ) {
        self.reader = reader
        self.calendar = calendar
        self.now = now
        self.posture = posture
        self.state = GlanceState(now: now(), calendar: calendar)
    }

    /// Runs until the task is cancelled, publishing after every step.
    public mutating func run(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        publish: @escaping @Sendable (GlanceState) async -> Void
    ) async {
        while !Task.isCancelled {
            let pause = await step()
            await publish(state)
            if let pause {
                do { try await sleep(pause) } catch { return }
            }
        }
    }

    /// One poll. Returns how long to wait before the next, or nil to poll again at once.
    public mutating func step() async -> Duration? {
        state.posture = posture()
        if needsPending, let pause = await reloadPending() { return pause }
        let started = now()
        // The first call reads from the oldest event rvd holds, so today's
        // numbers include what happened before the menu bar started.
        let params = EventsParams(stream: stream, after: cursor ?? 0, waitMs: Self.pollWaitMs)
        switch await reader.events(params) {
        case .events(let reply):
            backoff = Self.firstBackoff
            if reply.resync || (stream != nil && stream != reply.stream) { needsPending = true }
            stream = reply.stream
            cursor = reply.cursor
            state.apply(reply, now: now(), calendar: calendar)
            let quick = now().timeIntervalSince(started) < Self.emptyReplyFloor
            return reply.events.isEmpty && quick ? Self.firstBackoff : nil
        case .unsupported:
            state.link = .liveWithoutEvents
            state.roll(to: now(), calendar: calendar)
            needsPending = true
            return Self.pendingPollInterval
        case .down(let reason):
            return wentDown(reason)
        }
    }

    private mutating func reloadPending() async -> Duration? {
        switch await reader.pendingAsks() {
        case .success(let asks):
            state.replacePending(asks)
            needsPending = false
            return nil
        case .failure(let failure):
            return wentDown(failure.reason)
        }
    }

    private mutating func wentDown(_ reason: String) -> Duration {
        state.markDown(reason, at: now())
        needsPending = true
        let pause = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        return pause
    }
}
