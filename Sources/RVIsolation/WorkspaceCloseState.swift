import RVDomain

/// Admission and close election for one workspace supervisor.
///
/// The supervisor holds one value inside its state lock and is its only
/// mutator; the mutating functions are the only writers. `lifecycle` stays
/// the exact published `WorkspaceLifecycle` (wire rawValue), including
/// `.closing` after a terminal cleanup failure and `.closed` before the
/// leader caches its result.
///
/// Reachable (lifecycle, lead) states: (creating, none), (active, none),
/// (closing, none), (closing, leading), (closed, leading), (closed, finished),
/// (closing, finished(cleanupFailed)).
struct WorkspaceCloseState: Sendable {
    /// Who owns teardown. `.finished` means a leader ran to a cached result.
    /// `.none` with `.closing` means close was accepted but nobody is
    /// tearing down (test seam, or the last leader failed retryably).
    enum Lead: Sendable {
        case none
        case leading
        case finished(Result<Void, WorkspaceSessionError>)
    }

    /// What one `close()`/`discard()` caller does after the election.
    enum Role: Sendable {
        case lead(publish: Bool)
        case wait
        case finished(Result<Void, WorkspaceSessionError>)
    }

    private(set) var lifecycle: WorkspaceLifecycle = .creating
    private(set) var lead: Lead = .none

    /// New runtimes, preparations, dispatches, and redemptions.
    var acceptsRuntime: Bool { lifecycle.acceptsRuntime }

    /// `cancel(_:)` may address a child while active or closing.
    var acceptsCancel: Bool { lifecycle == .active || lifecycle == .closing }

    /// creating → active. False if the phase already moved.
    mutating func activate() -> Bool {
        guard let next = lifecycle.transition(.becameActive) else { return false }
        lifecycle = next
        return true
    }

    /// active → closing without electing a leader. Test seam: a later
    /// close still leads the real teardown.
    mutating func beginCloseWithoutLeader() -> Bool {
        guard let next = lifecycle.transition(.beginClose) else { return false }
        lifecycle = next
        return true
    }

    /// The close election. Precedence: a cached result replays; `.closed`
    /// answers `.alreadyClosed` (even while the leader has yet to cache its
    /// result); a running leader means wait; otherwise this caller leads,
    /// moving `.active` to `.closing` first.
    mutating func elect(publish: Bool) -> Role {
        if case .finished(let result) = lead {
            return .finished(result)
        }
        if lifecycle == .closed {
            return .finished(.failure(.alreadyClosed))
        }
        if case .leading = lead {
            return .wait
        }
        if lifecycle == .active {
            guard let closing = lifecycle.transition(.beginClose) else {
                return .finished(.failure(.notAcceptingRuntime(lifecycle)))
            }
            lifecycle = closing
        } else if lifecycle != .closing {
            return .finished(.failure(.notAcceptingRuntime(lifecycle)))
        }
        lead = .leading
        return .lead(publish: publish)
    }

    /// Leader only, after the boundary was restored: closing → closed.
    mutating func markClosed() {
        if let closed = lifecycle.transition(.becameClosed) {
            lifecycle = closed
        }
    }

    /// Leader only. A retryable failure releases the lead so a later close
    /// can publish; anything else is cached for replay.
    mutating func complete(_ result: Result<Void, WorkspaceSessionError>) {
        if case .failure(let error) = result, Self.failureIsTerminal(error) == false {
            // The children may die after this wait. A later close has
            // to be able to publish; caching this failure would not.
            lead = .none
        } else {
            lead = .finished(result)
        }
    }

    /// One waiter poll. Nil means keep waiting.
    func waiterOutcome() -> Result<Void, WorkspaceSessionError>? {
        if case .finished(let result) = lead {
            return result
        }
        // The leader stopped without publishing. Concurrent waiters
        // must observe that failure instead of waiting out the timeout.
        if case .none = lead, lifecycle == .closing {
            return .failure(.childTeardownFailed)
        }
        return nil
    }

    /// Whether a leader's close failure is cached for replay (terminal) or
    /// released so a later close can lead again (retryable). Only a close
    /// that stopped with children alive stays retryable: the children may
    /// die after the wait, so a later close must still be able to publish.
    /// Every other failure is terminal and replays without new work.
    static func failureIsTerminal(_ error: WorkspaceSessionError) -> Bool {
        switch error {
        case .childTeardownFailed:
            return false
        case .apply, .notAcceptingRuntime, .cleanupFailed, .publishRejected, .alreadyClosed,
            .unknownRuntime, .runtimeLimit, .ownedByLiveProcess,
            .recoveryInProgress, .unresolvedWorkspace, .preparationFailed,
            .unknownPreparedLaunch, .redemptionAlreadyAccepted:
            return true
        }
    }
}
