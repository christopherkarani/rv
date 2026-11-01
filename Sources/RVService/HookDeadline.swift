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
    private let tripped = Mutex(false)

    public init(receivedAt: ContinuousClock.Instant = .now, budget: Duration = HookDeadline.budget) {
        self.expiresAt = receivedAt.advanced(by: budget)
    }

    /// True while a client-visible side effect may still commit. Sticky:
    /// the first check past the budget trips it for the rest of the request,
    /// so a later step cannot commit after an earlier one was skipped.
    public func permitsSideEffects() -> Bool {
        tripped.withLock { tripped in
            if tripped { return false }
            if ContinuousClock.now >= expiresAt { tripped = true }
            return tripped == false
        }
    }

    /// True once any check found the budget spent: the reply must not claim
    /// effects (pending row, unlock code) that were skipped.
    public var hasTripped: Bool { tripped.withLock { $0 } }

    /// The bound deadline's verdict; true when no hookEvaluate budget applies.
    static func permitsSideEffects() -> Bool {
        current?.permitsSideEffects() ?? true
    }
}
