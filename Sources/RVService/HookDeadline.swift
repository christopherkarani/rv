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
    ///
    /// The full chain must stay ordered so the daemon always gives up first
    /// and never spends a grant on a reply the host already dropped. The C
    /// client sends the request no later than 5 s after it starts
    /// (`RV_EVALUATE_SEND_CUTOFF_MS`), so rvd is done by 5 + 7 = 12 s and
    /// the client by 5 + 8 = 13 s, both inside the 15 s host shim
    /// (`RV_HOOK_TIMEOUT_S` / `RV_HOOK_TIMEOUT_MS`) and the 18 s host hook
    /// configs (Codex, Cursor, Antigravity, Grok, Muse; Claude uses 90 s).
    /// `HookTimeoutChainTests` checks this.
    public static let budget: Duration = .seconds(7)

    /// The deadline of the hookEvaluate this task is serving, if any. Only
    /// `HookDoor.run` binds it; evaluate paths without it have no budget.
    @TaskLocal static var current: HookDeadline?

    /// When the budget runs out. `JudgeAdmission` bounds its model wait by it.
    let expiresAt: ContinuousClock.Instant
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

    /// Claims the right to spend an allow-once grant: false (and tripped)
    /// once the budget has passed, so the grant stays live for the retry.
    /// True marks the grant spent; its allow must then reach the client,
    /// since swapping in the timeout deny would burn the human's approval.
    /// The table calls this inside the actor, right before removal, so the
    /// deadline check and the spend cannot be separated by a suspension.
    func claimGrantSpend() -> Bool {
        let current = now()
        return state.withLock { state in
            if state.tripped == false, current >= expiresAt { state.tripped = true }
            guard state.tripped == false else { return false }
            state.grantSpent = true
            return true
        }
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
