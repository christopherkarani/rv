import Dispatch
import Synchronization

/// Bounds the queue in front of the judge model, which answers one request
/// at a time.
///
/// Without a bound, a burst of judged commands queues behind the model.
/// The C hook client gives up after 8 s, but rvd kept serving the request it
/// dropped, and the agent's retry joined the same queue: every new request
/// waited longer than the last (seen live: 10 s growing to 107 s), so every
/// judged command failed as if rvd were down.
///
/// A request is refused at once when `limit` requests are already admitted,
/// and its wait for the model ends at its hook deadline. A refused request
/// never runs the model; the caller fails it closed (`JudgeRun.busy`).
final class JudgeAdmission: Sendable {
    /// Requests admitted at once (one on the model, the rest waiting).
    /// Inference is typically well under a second, so a full queue clears
    /// inside the daemon's 7 s `HookDeadline.budget`.
    static let liveLimit = 4

    /// The admission every live judge call goes through.
    static let live = JudgeAdmission(limit: liveLimit)

    /// The hook deadline of the request this thread is judging, if any.
    /// `JudgeOffload.run` binds it: the judge runs on a Dispatch thread,
    /// where the task-local `HookDeadline.current` is not visible. Only
    /// the judge reads it, so binding it changes no other deadline check.
    @TaskLocal static var deadline: ContinuousClock.Instant?

    private let limit: Int
    private let count = Mutex(0)
    private let model = DispatchSemaphore(value: 1)

    init(limit: Int) {
        precondition(limit > 0, "JudgeAdmission needs room for at least one request")
        self.limit = limit
    }

    /// Requests currently admitted (running or waiting). Test seam.
    var admitted: Int { count.withLock { $0 } }

    /// Runs `body` with the model to itself, or returns nil without running
    /// it when the queue is full or `deadline` passes first. A nil deadline
    /// waits for the model as long as it takes (still bounded by `limit`).
    func run<T>(until deadline: ContinuousClock.Instant?, _ body: () -> T) -> T? {
        if let deadline, deadline <= ContinuousClock.now { return nil }
        let entered = count.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
        guard entered else { return nil }
        defer { count.withLock { $0 -= 1 } }
        guard model.wait(timeout: Self.dispatchTime(until: deadline)) == .success else { return nil }
        defer { model.signal() }
        return body()
    }

    /// The wait for an in-progress model load, shortened to what is left of
    /// the hook deadline: a cold load must not hold a request past the
    /// point its client gives up. nil `wait` (no bound) with no deadline
    /// stays nil.
    static func loadWait(
        _ wait: Duration?,
        until deadline: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now
    ) -> Duration? {
        guard let deadline else { return wait }
        let remaining = max(deadline - now, .zero)
        guard let wait else { return remaining }
        return min(wait, remaining)
    }

    private static func dispatchTime(until deadline: ContinuousClock.Instant?) -> DispatchTime {
        guard let deadline else { return .distantFuture }
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return .now() }
        let (seconds, attoseconds) = remaining.components
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard whole.overflow == false else { return .distantFuture }
        let total = whole.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000)
        guard total.overflow == false, let nanoseconds = Int(exactly: total.partialValue) else {
            return .distantFuture
        }
        return .now() + .nanoseconds(nanoseconds)
    }
}
