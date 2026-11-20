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
/// and its wait for the model slot ends at `waitBudget`, or earlier at its
/// hook deadline less `inferenceHeadroom`. (A cold model load before it has
/// its own bound, `JudgeRuntime.daemonLoadWait`.)
/// A refused request never runs the model; the caller fails it closed
/// (`JudgeRun.busy`, or `JudgeRun.late` when the model is stalled).
///
/// An admitted prediction cannot be cancelled. Under a hook deadline it
/// runs off the caller, who stops waiting at the deadline less
/// `replyMargin` and fails closed (`late`); the prediction keeps the model
/// until it returns and then reports itself through `onLate`.
final class JudgeAdmission: Sendable {
    /// Requests admitted at once (one on the model, the rest waiting).
    /// The bounded wait is what stops a backlog from piling up; this count
    /// only caps the Dispatch threads blocked on the model.
    static let liveLimit = 12

    /// The most a judged call with a deadline waits for the model slot
    /// (its turn behind other predictions). Judge latency is p50 0.3 s,
    /// p90 1.8 s; waiting longer behind another prediction mostly bought a
    /// review anyway, after holding the agent for seconds. A cold model
    /// load is not part of it: that wait is `JudgeRuntime.daemonLoadWait`,
    /// so a fresh rvd still gets its judge loaded on the first calls.
    /// Bounds waiting only: a prediction already running is not stopped
    /// (Phase 1 moves the judge out of process, where it can be killed).
    static let waitBudget: Duration = .milliseconds(1500)

    /// Time kept back for the inference itself: a request waits for a slot
    /// only until `deadline - inferenceHeadroom`, so work it admits can
    /// finish before the client gives up. It covers `replyMargin` plus a
    /// second of inference (p50 0.3 s): with less, a call taking the slot
    /// at its cutoff would almost always answer `late`, a circuit failure
    /// for a healthy judge.
    static let inferenceHeadroom: Duration = replyMargin + .seconds(1)

    /// Time kept back after inference for the rest of the reply: a caller
    /// stops waiting for its prediction at `deadline - replyMargin` and
    /// answers `late` (review) rather than running into the timeout deny.
    /// It must cover the Policy gate, the pending-approval row and the
    /// unlock-code mint on a loaded machine; any of them past the deadline
    /// swaps the review for the timeout deny (`requiresTimeoutReply`).
    static let replyMargin: Duration = .milliseconds(750)

    /// A prediction running this long can no longer answer any hook, so a
    /// request turned away behind it was turned away by a stalled judge.
    static let stallAge: Duration = HookDeadline.budget

    /// The admission every live judge call goes through.
    static let live = JudgeAdmission(limit: liveLimit)

    /// The judge deadline of the request this thread is judging, if any:
    /// its hook deadline, or the non-hook judge budget counted from when
    /// the offloaded work started (`JudgeOffload.run` binds it; the judge
    /// runs on a Dispatch thread, where `HookDeadline.current` is not
    /// visible). Only the judge reads it: pattern search and side-effect
    /// checks use the hook deadline alone (`JudgeOffload.hookDeadline`,
    /// `HookDeadline`), so a non-hook judge bound never cuts them short.
    @TaskLocal static var deadline: ContinuousClock.Instant?

    /// What one request came to.
    enum Outcome<T: Sendable>: Sendable {
        /// The prediction answered in time.
        case answered(T)
        /// Never ran: queue full, or the slot wait ran out. `stalled`: the
        /// prediction holding the model had already outrun its own caller
        /// or `stallAge`.
        case turnedAway(stalled: Bool)
        /// Ran, but did not answer before the caller's cutoff.
        case late
    }

    /// The prediction holding the model.
    private struct Holder {
        let token: UInt64
        let since: ContinuousClock.Instant
        var abandoned = false
    }

    private struct State {
        var count = 0
        var holder: Holder?
        var nextToken: UInt64 = 0
    }

    private let limit: Int
    private let stallAge: Duration
    private let state = Mutex(State())
    private let model = DispatchSemaphore(value: 1)
    private static let inference = DispatchQueue(
        label: "rv.judge.inference", qos: .userInitiated, attributes: .concurrent)

    /// `stallAge` is a test seam; production uses `JudgeAdmission.stallAge`.
    init(limit: Int, stallAge: Duration = JudgeAdmission.stallAge) {
        precondition(limit > 0, "JudgeAdmission needs room for at least one request")
        self.limit = limit
        self.stallAge = stallAge
    }

    /// Requests currently admitted (running or waiting). Test seam.
    var admitted: Int { state.withLock { $0.count } }

    /// The end of a wait for a verdict slot that started at `since`: the
    /// budget or the deadline less headroom, whichever comes first. A nil
    /// deadline (the CLI's in-process path) waits as long as it takes.
    static func slotCutoff(
        until deadline: ContinuousClock.Instant?, since: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        deadline.map { min(since.advanced(by: waitBudget), $0 - inferenceHeadroom) }
    }

    /// Runs `body` with the model to itself. Turns the request away without
    /// running it when the queue is full or the slot cutoff (counted from
    /// `since`) passes first. With a deadline, stops waiting for the
    /// prediction at `deadline - replyMargin` (`late`); the prediction then
    /// calls `onLate` with its result and run time when it returns. A nil
    /// deadline waits for the model and the prediction as long as they
    /// take (still bounded by `limit`).
    func run<T: Sendable>(
        until deadline: ContinuousClock.Instant?,
        since: ContinuousClock.Instant = .now,
        onLate: @escaping @Sendable (T, Duration) -> Void = { _, _ in },
        _ body: @escaping @Sendable () -> T
    ) -> Outcome<T> {
        let cutoff = Self.slotCutoff(until: deadline, since: since)
        if let cutoff, cutoff <= ContinuousClock.now { return .turnedAway(stalled: stalled()) }
        let entered = state.withLock { state in
            guard state.count < limit else { return false }
            state.count += 1
            return true
        }
        guard entered else { return .turnedAway(stalled: stalled()) }
        defer { state.withLock { $0.count -= 1 } }
        guard model.wait(timeout: Self.dispatchTime(until: cutoff)) == .success else {
            return .turnedAway(stalled: stalled())
        }
        let began = ContinuousClock.now
        let token = state.withLock { state in
            state.nextToken &+= 1
            state.holder = Holder(token: state.nextToken, since: began)
            return state.nextToken
        }
        guard let deadline else {
            defer { release(token) }
            return .answered(body())
        }
        let delivery = Delivery<T>()
        Self.inference.async { [self] in
            let value = body()
            let ran = ContinuousClock.now - began
            release(token)
            if delivery.deliver(value) == false { onLate(value, ran) }
        }
        _ = delivery.wait(until: deadline - Self.replyMargin)
        if let value = delivery.abandon() { return .answered(value) }
        state.withLock { state in
            if state.holder?.token == token { state.holder?.abandoned = true }
        }
        return .late
    }

    /// Frees the model once prediction `token` returns.
    private func release(_ token: UInt64) {
        state.withLock { state in
            if state.holder?.token == token { state.holder = nil }
        }
        model.signal()
    }

    /// Whether the prediction holding the model is past saving.
    private func stalled(now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { state in
            guard let holder = state.holder else { return false }
            return holder.abandoned || now - holder.since >= stallAge
        }
    }

    /// The wait for an in-progress model load, shortened to what is left
    /// before `cutoff` (the hook deadline less `inferenceHeadroom`): a cold
    /// load must not hold a request past the point its client gives up.
    /// nil `wait` (no bound) with no cutoff stays nil.
    static func loadWait(
        _ wait: Duration?,
        until cutoff: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now
    ) -> Duration? {
        guard let cutoff else { return wait }
        let remaining = max(cutoff - now, .zero)
        guard let wait else { return remaining }
        return min(wait, remaining)
    }

    private static func dispatchTime(until deadline: ContinuousClock.Instant?) -> DispatchTime {
        guard let deadline else { return .distantFuture }
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return .now() }
        return .now() + dispatchInterval(remaining)
    }
}

/// One prediction's result, handed from the inference thread to a caller
/// that may already have stopped waiting.
private final class Delivery<T: Sendable>: Sendable {
    private enum State {
        case pending
        case delivered(T)
        case abandoned
    }

    private let state = Mutex(State.pending)
    private let ready = DispatchSemaphore(value: 0)

    /// False when the caller already gave up: the result is late.
    func deliver(_ value: T) -> Bool {
        let taken = state.withLock { state in
            guard case .pending = state else { return false }
            state = .delivered(value)
            return true
        }
        if taken { ready.signal() }
        return taken
    }

    /// Waits for the result until `cutoff`; true when it arrived.
    func wait(until cutoff: ContinuousClock.Instant) -> Bool {
        let remaining = cutoff - ContinuousClock.now
        let timeout: DispatchTime = remaining > .zero ? .now() + dispatchInterval(remaining) : .now()
        return ready.wait(timeout: timeout) == .success
    }

    /// The result if it arrived; otherwise marks the caller gone and
    /// returns nil, so a later `deliver` reports late.
    func abandon() -> T? {
        state.withLock { state in
            if case .delivered(let value) = state { return value }
            state = .abandoned
            return nil
        }
    }
}
