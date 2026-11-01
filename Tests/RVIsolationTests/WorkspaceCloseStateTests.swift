import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Pure close/admission election for one workspace supervisor.
///
/// `WorkspaceCloseState` is the value the supervisor holds inside its lock.
/// These tests drive it directly, so they run on Linux as well as macOS.
/// The supervisor-backed suites (WorkspaceLifecycleTests and friends) cover
/// the threads, waits, and the volume.
@Suite struct WorkspaceCloseStateTests {
    @Test func activatesOnceFromCreating() {
        var close = WorkspaceCloseState()
        #expect(close.lifecycle == .creating)
        let first = close.activate()
        #expect(first)
        #expect(close.lifecycle == .active)
        let second = close.activate()
        #expect(second == false)
        #expect(close.lifecycle == .active)
    }

    @Test func creatingRefusesCloseWithItsPhase() {
        var close = WorkspaceCloseState()
        expectFinished(close.elect(publish: true), .failure(.notAcceptingRuntime(.creating)))
        #expect(close.lifecycle == .creating)
        #expect(close.lead.kind == .none)
    }

    @Test func electionLeadsAndStopsAdmission() {
        var close = active()
        #expect(close.acceptsRuntime)
        #expect(close.acceptsCancel)
        expectLead(close.elect(publish: true), publish: true)
        #expect(close.lifecycle == .closing)
        #expect(close.lead.kind == .leading)
        #expect(close.acceptsRuntime == false)
        #expect(close.acceptsCancel)
    }

    @Test func secondElectionWaitsWhileLeading() {
        var close = active()
        _ = close.elect(publish: true)
        guard case .wait = close.elect(publish: false) else {
            Issue.record("a second close while a leader runs must wait")
            return
        }
        #expect(close.waiterOutcome() == nil)
        #expect(close.lead.kind == .leading)
    }

    @Test func retryableFailureReleasesTheLead() {
        var close = active()
        _ = close.elect(publish: true)
        close.complete(.failure(.childTeardownFailed))
        #expect(close.lead.kind == .none)
        #expect(close.lifecycle == .closing)
        expectOutcome(close.waiterOutcome(), .failure(.childTeardownFailed))
        expectLead(close.elect(publish: false), publish: false)
        #expect(close.lifecycle == .closing)
        #expect(close.lead.kind == .leading)
    }

    @Test func terminalCleanupFailureStaysClosingAndReplays() {
        var close = active()
        _ = close.elect(publish: true)
        let failure: Result<Void, WorkspaceSessionError> =
            .failure(.cleanupFailed(.workspaceInodeBoundaryFailed))
        close.complete(failure)
        // Published phase stays `.closing`: the boundary was never restored.
        #expect(close.lifecycle == .closing)
        #expect(close.acceptsRuntime == false)
        expectOutcome(close.waiterOutcome(), failure)
        expectFinished(close.elect(publish: true), failure)
        expectFinished(close.elect(publish: false), failure)
    }

    @Test func successAfterMarkClosedReplays() {
        var close = active()
        _ = close.elect(publish: true)
        close.markClosed()
        close.complete(.success(()))
        #expect(close.lifecycle == .closed)
        #expect(close.acceptsRuntime == false)
        #expect(close.acceptsCancel == false)
        expectOutcome(close.waiterOutcome(), .success(()))
        expectFinished(close.elect(publish: false), .success(()))
    }

    @Test func applyFailureAfterMarkClosedIsTerminal() {
        var close = active()
        _ = close.elect(publish: true)
        close.markClosed()
        let failure: Result<Void, WorkspaceSessionError> = .failure(.apply(.sessionRecordFailed))
        close.complete(failure)
        #expect(close.lifecycle == .closed)
        expectFinished(close.elect(publish: true), failure)
    }

    /// Pins a known quirk: a close arriving after the leader restored the
    /// boundary but before it cached its result answers `.alreadyClosed`
    /// instead of waiting. Changing this is a separate, tested decision.
    @Test func closedBeforeCompletionAnswersAlreadyClosed() {
        var close = active()
        _ = close.elect(publish: true)
        close.markClosed()
        #expect(close.lifecycle == .closed)
        #expect(close.lead.kind == .leading)
        expectFinished(close.elect(publish: true), .failure(.alreadyClosed))
        #expect(close.waiterOutcome() == nil)
        #expect(close.lead.kind == .leading)
    }

    @Test func leaderlessClosingLetsTheNextCloseLead() {
        var close = active()
        let began = close.beginCloseWithoutLeader()
        #expect(began)
        #expect(close.lifecycle == .closing)
        #expect(close.lead.kind == .none)
        #expect(close.acceptsRuntime == false)
        expectOutcome(close.waiterOutcome(), .failure(.childTeardownFailed))
        expectLead(close.elect(publish: false), publish: false)
        #expect(close.lead.kind == .leading)
    }

    @Test func beginCloseWithoutLeaderOnlyFromActive() {
        var creating = WorkspaceCloseState()
        let fromCreating = creating.beginCloseWithoutLeader()
        #expect(fromCreating == false)
        #expect(creating.lifecycle == .creating)

        var closing = active()
        let fromActive = closing.beginCloseWithoutLeader()
        #expect(fromActive)
        let fromClosing = closing.beginCloseWithoutLeader()
        #expect(fromClosing == false)

        var closed = active()
        _ = closed.elect(publish: true)
        closed.markClosed()
        let fromClosed = closed.beginCloseWithoutLeader()
        #expect(fromClosed == false)
        #expect(closed.lifecycle == .closed)
    }

    @Test(arguments: [WorkspaceLifecycle.creating, .active, .closing, .closed])
    func admissionMatchesDomainPhase(_ phase: WorkspaceLifecycle) {
        var close = WorkspaceCloseState()
        switch phase {
        case .creating:
            break
        case .active:
            _ = close.activate()
        case .closing:
            _ = close.activate()
            _ = close.elect(publish: true)
        case .closed:
            _ = close.activate()
            _ = close.elect(publish: true)
            close.markClosed()
        }
        #expect(close.lifecycle == phase)
        #expect(close.acceptsRuntime == phase.acceptsRuntime)
        #expect(close.acceptsCancel == (phase == .active || phase == .closing))
    }

    @Test func failureIsTerminalOnlyKeepsChildTeardownRetryable() {
        #expect(WorkspaceCloseState.failureIsTerminal(.childTeardownFailed) == false)
        for error in Self.terminalErrors {
            #expect(WorkspaceCloseState.failureIsTerminal(error), "\(error) must be terminal")
        }
    }

    #if os(macOS)
    @Test func failureIsTerminalMatchesSupervisorPredicate() {
        for error in Self.terminalErrors + [.childTeardownFailed] {
            #expect(
                WorkspaceSessionSupervisor.closeFailureIsTerminal(error)
                    == WorkspaceCloseState.failureIsTerminal(error)
            )
        }
    }
    #endif

    /// Breadth-first over the supervisor's protocol: anyone may activate,
    /// begin close without a leader, or elect; only a leader marks closed
    /// or completes, and only with the outcomes `performFinish` can return
    /// at that point.
    @Test func boundedExplorationKeepsInvariants() {
        var seen: Set<StateKey> = []
        var kinds: Set<Coarse> = []
        var frontier = [WorkspaceCloseState()]
        var depth = 0
        while frontier.isEmpty == false, depth < 12 {
            var next: [WorkspaceCloseState] = []
            for state in frontier where seen.insert(StateKey(state)).inserted {
                kinds.insert(Coarse(state))
                checkInvariants(state)
                for event in Event.allowed(in: state) {
                    var after = state
                    let role = event.apply(to: &after)
                    checkStep(from: state, event: event, role: role, to: after)
                    if seen.contains(StateKey(after)) == false {
                        next.append(after)
                    }
                }
            }
            frontier = next
            depth += 1
        }
        #expect(frontier.isEmpty, "exploration must reach a fixed point within the bound")
        let expected: Set<Coarse> = [
            Coarse(.creating, .none),
            Coarse(.active, .none),
            Coarse(.closing, .none),
            Coarse(.closing, .leading),
            Coarse(.closed, .leading),
            Coarse(.closed, .finished),
            Coarse(.closing, .finished),
        ]
        #expect(kinds == expected)
        #expect(kinds.count == 7)
    }
}

// MARK: - Helpers

extension WorkspaceCloseStateTests {
    static let terminalErrors: [WorkspaceSessionError] = [
        .apply(.workspaceInodeBoundaryFailed),
        .notAcceptingRuntime(.closing),
        .cleanupFailed(.workspaceInodeBoundaryFailed),
        .alreadyClosed,
        .unknownRuntime(RuntimeSessionID()),
        .runtimeLimit,
        .ownedByLiveProcess(nil),
        .recoveryInProgress(UUID()),
        .unresolvedWorkspace(WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog)),
        .preparationFailed(.workspaceNotActive),
        .unknownPreparedLaunch,
        .redemptionAlreadyAccepted,
    ]

    private func active() -> WorkspaceCloseState {
        var close = WorkspaceCloseState()
        _ = close.activate()
        return close
    }

    private func checkInvariants(_ state: WorkspaceCloseState) {
        #expect(state.acceptsRuntime == (state.lifecycle == .active))
        if state.lead.kind != .none {
            #expect(state.lifecycle == .closing || state.lifecycle == .closed)
        }
        if state.lifecycle == .closed {
            #expect(state.lead.kind != .none)
        }
    }

    private func checkStep(
        from before: WorkspaceCloseState,
        event: Event,
        role: WorkspaceCloseState.Role?,
        to after: WorkspaceCloseState
    ) {
        if after.lifecycle == .active {
            #expect(before.lifecycle == .creating || before.lifecycle == .active, "\(event)")
        }
        if case .finished(let cached) = before.lead {
            #expect(after.lifecycle == before.lifecycle, "\(event)")
            guard case .finished(let still) = after.lead else {
                Issue.record("finished must be absorbing after \(event)")
                return
            }
            #expect(Outcome(still) == Outcome(cached))
            if let role {
                expectFinished(role, cached)
            }
        }
        if case .lead = role {
            #expect(before.lead.kind == .none, "\(event)")
            #expect(after.lifecycle == .closing)
            #expect(after.lead.kind == .leading)
        }
    }
}

private func expectLead(
    _ role: WorkspaceCloseState.Role,
    publish expected: Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .lead(let publish) = role else {
        Issue.record("expected .lead, got \(role)", sourceLocation: sourceLocation)
        return
    }
    #expect(publish == expected, sourceLocation: sourceLocation)
}

private func expectFinished(
    _ role: WorkspaceCloseState.Role,
    _ expected: Result<Void, WorkspaceSessionError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .finished(let result) = role else {
        Issue.record("expected .finished, got \(role)", sourceLocation: sourceLocation)
        return
    }
    #expect(Outcome(result) == Outcome(expected), sourceLocation: sourceLocation)
}

private func expectOutcome(
    _ outcome: Result<Void, WorkspaceSessionError>?,
    _ expected: Result<Void, WorkspaceSessionError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let outcome else {
        Issue.record("expected a waiter outcome, got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(Outcome(outcome) == Outcome(expected), sourceLocation: sourceLocation)
}

/// `Result<Void, _>` is not Equatable; compare through this.
private enum Outcome: Hashable {
    case success
    case failure(String)

    init(_ result: Result<Void, WorkspaceSessionError>) {
        switch result {
        case .success: self = .success
        case .failure(let error): self = .failure(String(describing: error))
        }
    }
}

private enum LeadKind: Hashable {
    case none, leading, finished
}

extension WorkspaceCloseState.Lead {
    fileprivate var kind: LeadKind {
        switch self {
        case .none: .none
        case .leading: .leading
        case .finished: .finished
        }
    }
}

/// The seven states of §1.2: lifecycle × lead kind.
private struct Coarse: Hashable {
    let lifecycle: WorkspaceLifecycle
    let lead: LeadKind

    init(_ lifecycle: WorkspaceLifecycle, _ lead: LeadKind) {
        self.lifecycle = lifecycle
        self.lead = lead
    }

    init(_ state: WorkspaceCloseState) {
        self.init(state.lifecycle, state.lead.kind)
    }
}

/// Full identity, including the cached result, for exploration dedup.
private struct StateKey: Hashable {
    let coarse: Coarse
    let cached: Outcome?

    init(_ state: WorkspaceCloseState) {
        coarse = Coarse(state)
        if case .finished(let result) = state.lead {
            cached = Outcome(result)
        } else {
            cached = nil
        }
    }
}

private enum Event: CustomStringConvertible {
    case activate
    case beginCloseWithoutLeader
    case elect(publish: Bool)
    case markClosed
    case complete(Result<Void, WorkspaceSessionError>)

    /// Supervisor protocol: `markClosed`/`complete` only while leading, and
    /// only with outcomes `performFinish` returns from that phase.
    static func allowed(in state: WorkspaceCloseState) -> [Event] {
        var events: [Event] = [.activate, .beginCloseWithoutLeader, .elect(publish: true), .elect(publish: false)]
        guard case .leading = state.lead else { return events }
        switch state.lifecycle {
        case .closing:
            events += [
                .markClosed,
                .complete(.failure(.childTeardownFailed)),
                .complete(.failure(.cleanupFailed(.workspaceInodeBoundaryFailed))),
            ]
        case .closed:
            events += [
                .complete(.success(())),
                .complete(.failure(.apply(.sessionRecordFailed))),
            ]
        case .creating, .active:
            break
        }
        return events
    }

    /// Applies the event; returns the election role for `elect`.
    func apply(to state: inout WorkspaceCloseState) -> WorkspaceCloseState.Role? {
        switch self {
        case .activate:
            _ = state.activate()
        case .beginCloseWithoutLeader:
            _ = state.beginCloseWithoutLeader()
        case .elect(let publish):
            return state.elect(publish: publish)
        case .markClosed:
            state.markClosed()
        case .complete(let result):
            state.complete(result)
        }
        return nil
    }

    var description: String {
        switch self {
        case .activate: "activate"
        case .beginCloseWithoutLeader: "beginCloseWithoutLeader"
        case .elect(let publish): "elect(publish: \(publish))"
        case .markClosed: "markClosed"
        case .complete(let result): "complete(\(Outcome(result)))"
        }
    }
}
