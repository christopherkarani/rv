import Synchronization

/// Daemon-side budget for one `hookEvaluate`.
///
/// The C hook client fails closed when its reply does not arrive in time and
/// shows the user a block. Work the daemon commits after that point is work
/// for a reply nobody reads: a spent allow-once grant, a pending-approval row,
/// a minted unlock code, a denial-ledger row. Each such side effect asks
/// `permitsSideEffects()` first; once the budget has passed, they are all
/// skipped and the reply becomes a timeout deny.
///
/// The budget runs from the transport's receipt of the frame (before any
/// actor hop), so time spent queued behind other work counts.
public final class HookDeadline: Sendable {
    /// Must stay below the C client's 8 s hookEvaluate timeout in
    /// Sources/rv-c/rv.c, leaving room for the reply to travel back.
    public static let budget: Duration = .seconds(7)

    /// The deadline of the hookEvaluate this task is serving, if any. Only
    /// `HookDoor.run` binds it; evaluate paths without it have no budget.
    @TaskLocal static var current: HookDeadline?

    private let expiresAt: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private struct State {
        var tripped = false
        var grantSpent = false
    }

    private let state = Mutex(State())

    public convenience init(
        receivedAt: ContinuousClock.Instant = .now,
        budget: Duration = HookDeadline.budget
    ) {
        self.init(expiresAt: receivedAt.advanced(by: budget), now: { .now })
    }

    init(expiresAt: ContinuousClock.Instant, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.expiresAt = expiresAt
        self.now = now
    }

    /// True while a client-visible side effect may still commit. Sticky:
    /// the first check past the budget trips it for the rest of the request,
    /// so a later step cannot commit after an earlier one was skipped.
    public func permitsSideEffects() -> Bool {
        let current = now()
        return state.withLock { state in
            if state.tripped { return false }
            if current >= expiresAt { state.tripped = true }
            return state.tripped == false
        }
    }

    /// True once any check found the budget spent: the reply must not claim
    /// effects (pending row, unlock code) that were skipped.
    public var hasTripped: Bool { state.withLock { $0.tripped } }

    /// Records that an allow-once grant was spent (inside the budget) and
    /// the reply now carries that allow. It must reach the client: swapping
    /// in the timeout deny would burn the human's approval for nothing.
    func recordGrantSpent() {
        state.withLock { $0.grantSpent = true }
    }

    /// True when the reply must be replaced by the timeout deny: a side
    /// effect was skipped and no grant was spent on this request.
    var requiresTimeoutReply: Bool {
        state.withLock { $0.tripped && $0.grantSpent == false }
    }

    /// The bound deadline's verdict; true when no hookEvaluate budget applies.
    static func permitsSideEffects() -> Bool {
        current?.permitsSideEffects() ?? true
    }
}
