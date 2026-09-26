import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Scripted lifecycle sequences. These tests drive only the pure
/// transition; they spawn zero processes by construction.
@Suite("Workspace lifecycle core")
struct WorkspaceLifecycleTests {
    private typealias T = WorkspaceLifecycleTransition

    @discardableResult
    private func step(
        _ state: WorkspaceSupervisorState,
        _ event: WorkspaceEvent
    ) -> (state: WorkspaceSupervisorState, effects: WorkspaceEffects) {
        T.transition(state: state, event: event)
    }

    private func run(
        from initial: WorkspaceSupervisorState = .initial(),
        _ events: [WorkspaceEvent]
    ) -> (state: WorkspaceSupervisorState, effects: [[WorkspaceEffect]]) {
        var state = initial
        var all: [[WorkspaceEffect]] = []
        for event in events {
            let out = T.transition(state: state, event: event)
            state = out.state
            all.append(out.effects.effects)
        }
        return (state, all)
    }

    private func active() -> WorkspaceSupervisorState {
        let (state, _) = run([.recoveryReported(.clean), .openCompleted])
        return state
    }

    @Test func openSequenceReachesActive() {
        let (state, effects) = run([.recoveryReported(.clean), .openCompleted])
        #expect(effects[0] == [.establishBoundary])
        #expect(effects[1] == [])
        #expect(state.phase == .active)
        #expect(state.admissionPending == false)
    }

    @Test func recoveredWorkspaceAdmits() {
        let id = UUID()
        let (state, effects) = run([.recoveryReported(.recovered(id))])
        #expect(effects == [[.establishBoundary]])
        #expect(state.phase == .creating)
        #expect(state.admissionPending == false)
    }

    @Test func liveOwnerRefusesOpenAndDrains() {
        let outcome = WorkspaceRecoveryOutcome.liveOwner(nil)
        let (state, effects) = run([.recoveryReported(outcome)])
        #expect(effects == [[.replyOpenRefused(outcome), .releaseOwnership]])
        #expect(state.phase == .closed)
        // Terminal: later inputs drain without new work.
        let id = RuntimeSessionID()
        #expect(step(state, .recoveryReported(.clean)).effects.effects == [])
        #expect(
            step(state, .spawnRequested(id)).effects.effects
                == [.replySpawnRefused(id, .notAccepting(.closed))]
        )
        #expect(step(state, .closeRequested(publish: true)).effects.effects == [.replyAlreadyClosed])
        #expect(step(state, .controlReplyReceived(id)).effects.effects == [])
    }

    @Test func blockedRecoveryRefusesOpen() {
        let block = WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog)
        let outcome = WorkspaceRecoveryOutcome.blocked(block)
        let (state, effects) = run([.recoveryReported(outcome)])
        #expect(effects == [[.replyOpenRefused(outcome), .releaseOwnership]])
        #expect(state.phase == .closed)
    }

    @Test func failedRecoveryRefusesTheAttemptButAllowsRetry() {
        let (state, _) = run([.recoveryReported(.failed)])
        #expect(state.phase == .closed)
        // A fresh state for the retry admits normally.
        let (retry, effects) = run([.recoveryReported(.clean), .openCompleted])
        #expect(effects[0] == [.establishBoundary])
        #expect(retry.phase == .active)
    }

    @Test func allRefusalOutcomesRefuseTheAttempt() {
        let block = WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog)
        let refusals: [WorkspaceRecoveryOutcome] = [
            .liveOwner(nil),
            .liveOwner(UUID()),
            .recoveryInProgress(UUID()),
            .blocked(block),
            .interrupted(.afterPublish),
            .failed,
        ]
        for outcome in refusals {
            let (state, effects) = run([.recoveryReported(outcome)])
            #expect(
                effects == [[.replyOpenRefused(outcome), .releaseOwnership]],
                "outcome \(outcome) must refuse the attempt"
            )
            #expect(state.phase == .closed, "outcome \(outcome) must close the attempt")
            #expect(state.admissionPending == false)
        }
    }

    @Test func duplicateRecoveryReportDrains() {
        let (state, _) = run([.recoveryReported(.clean)])
        let out = step(state, .recoveryReported(.clean))
        #expect(out.effects.effects == [])
        #expect(out.state == state)
    }

    @Test func openFailureDiscardsTheWorkspace() {
        let (state, effects) = run([.recoveryReported(.clean), .openFailed])
        #expect(effects[1] == [.discardWorkspace, .releaseOwnership])
        #expect(state.phase == .closed)
    }

    @Test func launchHandshakeSequence() {
        let id = RuntimeSessionID()
        let (state, effects) = run(
            from: active(),
            [.spawnRequested(id), .spawnRecorded(id), .handshakeSucceeded(id)]
        )
        #expect(effects[0] == [.spawnRuntime(id)])
        #expect(effects[1] == [.resumeRuntime(id)])
        #expect(effects[2] == [])
        #expect(state.runtimes[id] == .established)
        #expect(state.phase == .active)
    }

    @Test func spawnFailureEndsTheRuntime() {
        let id = RuntimeSessionID()
        let (state, effects) = run(
            from: active(),
            [.spawnRequested(id), .spawnFailed(id)]
        )
        #expect(effects[1] == [.appendRuntimeEnded(id)])
        #expect(state.runtimes[id] == nil)
    }

    @Test func duplicateSpawnRequestDrains() {
        // The supervisor mints a fresh id per spawn, so a duplicate names an
        // already-tracked runtime and drains without a second spawn.
        let id = RuntimeSessionID()
        let requested = step(active(), .spawnRequested(id))
        #expect(requested.effects.effects == [.spawnRuntime(id)])
        let duplicate = step(requested.state, .spawnRequested(id))
        #expect(duplicate.effects.effects == [])
        #expect(duplicate.state == requested.state)
        // Still tracked after a duplicate: the original request proceeds.
        let recorded = step(duplicate.state, .spawnRecorded(id))
        #expect(recorded.effects.effects == [.resumeRuntime(id)])
        #expect(recorded.state.runtimes[id] == .handshaking)
    }

    @Test func mismatchedPhaseCompletionsDrain() {
        let starting = RuntimeSessionID()
        let established = RuntimeSessionID()
        var state = active()
        state = step(state, .spawnRequested(starting)).state
        for event: WorkspaceEvent in [
            .spawnRequested(established), .spawnRecorded(established), .handshakeSucceeded(established),
        ] {
            state = step(state, event).state
        }
        // Known ids, wrong phases: every completion guard must hold.
        let mismatches: [WorkspaceEvent] = [
            .spawnRecorded(established),
            .spawnFailed(established),
            .handshakeSucceeded(starting),
            .handshakeFailed(starting),
            .handshakeFailed(established),
            .runtimeForgotten(starting),
            .runtimeForgotten(established),
        ]
        for event in mismatches {
            let out = step(state, event)
            #expect(out.effects.effects == [], "mismatched \(event) must drain")
            #expect(out.state == state, "mismatched \(event) must not move state")
        }
    }

    @Test func handshakeFailureFailsTheRuntime() {
        let id = RuntimeSessionID()
        var state = active()
        for event: WorkspaceEvent in [.spawnRequested(id), .spawnRecorded(id)] {
            state = step(state, event).state
        }
        let out = step(state, .handshakeFailed(id))
        #expect(out.effects.effects == [.appendRuntimeEnded(id)])
        #expect(out.state.runtimes[id] == .failed)
        // A failed runtime cancels successfully and is then forgotten.
        #expect(step(out.state, .cancelRequested(id)).effects.effects == [.replyCancelled(id)])
        let forgotten = step(out.state, .runtimeForgotten(id))
        #expect(forgotten.state.runtimes[id] == nil)
    }

    @Test func spawnRefusedOutsideActive() {
        let id = RuntimeSessionID()
        for phaseState in [
            WorkspaceSupervisorState.initial(),
            run([.recoveryReported(.clean), .openCompleted, .closeRequested(publish: false)]).state,
            run([.recoveryReported(.liveOwner(nil))]).state,
        ] {
            let out = step(phaseState, .spawnRequested(id))
            #expect(
                out.effects.effects == [.replySpawnRefused(id, .notAccepting(phaseState.phase))]
            )
            #expect(out.state == phaseState)
        }
    }

    @Test func spawnRefusedAtLimit() {
        let first = RuntimeSessionID()
        let second = RuntimeSessionID()
        var state = WorkspaceSupervisorState.initial(runningLimit: 1)
        for event: WorkspaceEvent in [.recoveryReported(.clean), .openCompleted] {
            state = step(state, event).state
        }
        state = step(state, .spawnRequested(first)).state
        let refused = step(state, .spawnRequested(second))
        #expect(refused.effects.effects == [.replySpawnRefused(second, .limitReached)])
        #expect(refused.state.runtimes[second] == nil)
        // Configuration: the transition never mutates the cap.
        #expect(refused.state.runningLimit == 1)
        // An exited runtime frees its slot without being forgotten.
        let exited = step(state, .runtimeExited(first)).state
        let admitted = step(exited, .spawnRequested(second))
        #expect(admitted.effects.effects == [.spawnRuntime(second)])
    }

    @Test func spawnRefusedWhenBoundaryLost() {
        let id = RuntimeSessionID()
        let lost = step(active(), .boundaryLost)
        #expect(lost.effects.effects == [])
        #expect(lost.state.boundaryEstablished == false)
        let refused = step(lost.state, .spawnRequested(id))
        #expect(refused.effects.effects == [.replySpawnRefused(id, .boundaryLost)])
        // Losing the boundary twice changes nothing further.
        #expect(step(lost.state, .boundaryLost).state == lost.state)
    }

    @Test func cancelStopsARunningRuntime() {
        let id = RuntimeSessionID()
        var state = active()
        for event: WorkspaceEvent in [.spawnRequested(id), .spawnRecorded(id), .handshakeSucceeded(id)] {
            state = step(state, event).state
        }
        let cancelled = step(state, .cancelRequested(id))
        #expect(cancelled.effects.effects == [.stopRuntime(id)])
        #expect(cancelled.state.runtimes[id] == .exiting)
        // Cancel is idempotent while the runtime is still going.
        #expect(step(cancelled.state, .cancelRequested(id)).effects.effects == [.stopRuntime(id)])
        let exited = step(cancelled.state, .runtimeExited(id))
        #expect(exited.effects.effects == [.appendRuntimeEnded(id)])
        #expect(exited.state.runtimes[id] == .exited)
    }

    @Test func cancelUnknownRuntimeReplies() {
        let id = RuntimeSessionID()
        #expect(step(active(), .cancelRequested(id)).effects.effects == [.replyUnknownRuntime(id)])
        let closed = run([.recoveryReported(.liveOwner(nil))]).state
        #expect(step(closed, .cancelRequested(id)).effects.effects == [.replyUnknownRuntime(id)])
        #expect(step(.initial(), .cancelRequested(id)).effects.effects == [.replyUnknownRuntime(id)])
    }

    @Test func closePublishesAnEmptyWorkspace() {
        let requested = step(active(), .closeRequested(publish: true))
        #expect(requested.state.phase == .closing)
        #expect(requested.state.closeAccepted)
        #expect(requested.effects.effects == [.finishTeardown(publish: true)])
        let finished = step(requested.state, .closeSucceeded(published: true))
        #expect(
            finished.effects.effects
                == [.appendClosed(published: true), .releaseOwnership, .replyClosed(published: true)]
        )
        #expect(finished.state.phase == .closed)
        #expect(finished.state.publishCount == 1)
        // A second close replays the terminal answer without new work.
        let again = step(finished.state, .closeRequested(publish: true))
        #expect(again.effects.effects == [.replyAlreadyClosed])
        #expect(again.state == finished.state)
    }

    @Test func closeWithoutPublishDoesNotCount() {
        let requested = step(active(), .closeRequested(publish: false))
        #expect(requested.effects.effects == [.finishTeardown(publish: false)])
        let finished = step(requested.state, .closeSucceeded(published: false))
        #expect(finished.state.publishCount == 0)
        #expect(finished.state.phase == .closed)
    }

    @Test func closeStopsRuntimesThenFinishes() {
        let first = RuntimeSessionID()
        let second = RuntimeSessionID()
        var state = active()
        for id in [first, second] {
            for event: WorkspaceEvent in [.spawnRequested(id), .spawnRecorded(id), .handshakeSucceeded(id)] {
                state = step(state, event).state
            }
        }
        let requested = step(state, .closeRequested(publish: true))
        #expect(requested.state.phase == .closing)
        let stops = requested.effects.effects
        let ordered = [first, second].sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        #expect(stops == [.stopRuntime(ordered[0]), .stopRuntime(ordered[1]), .finishTeardown(publish: true)])
        // No new spawns while closing; exits only append records.
        let third = RuntimeSessionID()
        #expect(
            step(requested.state, .spawnRequested(third)).effects.effects
                == [.replySpawnRefused(third, .notAccepting(.closing))]
        )
        var closing = requested.state
        for id in [first, second] {
            let exited = step(closing, .runtimeExited(id))
            #expect(exited.effects.effects == [.appendRuntimeEnded(id)])
            closing = exited.state
        }
        let finished = step(closing, .closeSucceeded(published: true))
        #expect(finished.state.phase == .closed)
        #expect(finished.state.publishCount == 1)
    }

    @Test func closeDuringClosingWaitsForTheLeader() {
        let requested = step(active(), .closeRequested(publish: true))
        let waiter = step(requested.state, .closeRequested(publish: false))
        #expect(waiter.effects.effects == [.awaitClose])
        #expect(waiter.state == requested.state)
    }

    @Test func childrenAliveLeavesCloseRetryable() {
        let first = RuntimeSessionID()
        var state = active()
        for event: WorkspaceEvent in [.spawnRequested(first), .spawnRecorded(first), .handshakeSucceeded(first)] {
            state = step(state, event).state
        }
        let requested = step(state, .closeRequested(publish: true))
        let failed = step(requested.state, .closeFailed(.childrenAlive))
        #expect(failed.effects.effects == [.replyCloseFailed(.childrenAlive)])
        #expect(failed.state.phase == .closing)
        #expect(failed.state.terminalCloseFailure == nil)
        // Only successful publishes count; attempts do not.
        #expect(failed.state.publishCount == 0)
        // The next close leads again with its own publish flag.
        let reled = step(failed.state, .closeRequested(publish: false))
        #expect(
            reled.effects.effects == [.stopRuntime(first), .finishTeardown(publish: false)]
        )
        #expect(reled.state.closePublish == false)
        let exited = step(reled.state, .runtimeExited(first)).state
        let finished = step(exited, .closeSucceeded(published: false))
        #expect(finished.state.phase == .closed)
    }

    @Test func teardownFailedIsTerminal() {
        let requested = step(active(), .closeRequested(publish: true))
        let failed = step(requested.state, .closeFailed(.teardownFailed))
        #expect(failed.effects.effects == [.replyCloseFailed(.teardownFailed)])
        #expect(failed.state.phase == .closing)
        #expect(failed.state.publishCount == 0)
        // Later closes replay the failure without new work.
        let replayed = step(failed.state, .closeRequested(publish: false))
        #expect(replayed.effects.effects == [.replyCloseFailed(.teardownFailed)])
        #expect(replayed.state == failed.state)
        let third = RuntimeSessionID()
        #expect(
            step(failed.state, .spawnRequested(third)).effects.effects
                == [.replySpawnRefused(third, .notAccepting(.closing))]
        )
    }

    @Test func closeDuringCreatingIsRefused() {
        let out = step(.initial(), .closeRequested(publish: true))
        #expect(out.effects.effects == [.replyCloseRefused(.creating)])
        #expect(out.state.phase == .creating)
    }

    @Test func lateControlReplyDrains() {
        let running = RuntimeSessionID()
        let gone = RuntimeSessionID()
        var state = active()
        for id in [running, gone] {
            for event: WorkspaceEvent in [.spawnRequested(id), .spawnRecorded(id), .handshakeSucceeded(id)] {
                state = step(state, event).state
            }
        }
        state = step(state, .runtimeExited(gone)).state
        // A reply for a running runtime is forwarded ...
        #expect(
            step(state, .controlReplyReceived(running)).effects.effects
                == [.forwardControlReply(running)]
        )
        // ... but a reply that races an exit, names an unknown runtime, or
        // arrives after close drains to a no-op.
        #expect(step(state, .controlReplyReceived(gone)).effects.effects == [])
        #expect(step(state, .controlReplyReceived(RuntimeSessionID())).effects.effects == [])
        let closed = run([.recoveryReported(.liveOwner(nil))]).state
        #expect(step(closed, .controlReplyReceived(running)).effects.effects == [])
    }

    @Test func strayCompletionsDrain() {
        let id = RuntimeSessionID()
        let state = active()
        let strays: [WorkspaceEvent] = [
            .spawnRecorded(id),
            .spawnFailed(id),
            .handshakeSucceeded(id),
            .handshakeFailed(id),
            .runtimeExited(id),
            .runtimeForgotten(id),
            .openCompleted,
            .openFailed,
            .closeSucceeded(published: true),
            .closeFailed(.childrenAlive),
        ]
        for event in strays {
            let out = step(state, event)
            #expect(out.effects.effects == [], "stray \(event) must drain")
            #expect(out.state == state, "stray \(event) must not move state")
        }
        // A duplicate exit drains as well.
        var established = state
        for event: WorkspaceEvent in [.spawnRequested(id), .spawnRecorded(id), .handshakeSucceeded(id)] {
            established = step(established, event).state
        }
        let exited = step(established, .runtimeExited(id))
        let duplicate = step(exited.state, .runtimeExited(id))
        #expect(duplicate.effects.effects == [])
        #expect(duplicate.state == exited.state)
    }

    @Test func forgetPrunesOnlyFinishedRuntimes() {
        let finished = RuntimeSessionID()
        let running = RuntimeSessionID()
        var state = active()
        for id in [finished, running] {
            for event: WorkspaceEvent in [.spawnRequested(id), .spawnRecorded(id), .handshakeSucceeded(id)] {
                state = step(state, event).state
            }
        }
        state = step(state, .runtimeExited(finished)).state
        #expect(step(state, .runtimeForgotten(running)).state == state)
        #expect(step(state, .runtimeForgotten(RuntimeSessionID())).state == state)
        let pruned = step(state, .runtimeForgotten(finished))
        #expect(pruned.effects.effects == [])
        #expect(pruned.state.runtimes[finished] == nil)
        #expect(pruned.state.runtimes[running] == .established)
    }

    @Test func fullLifecycleScript() {
        let first = RuntimeSessionID()
        let second = RuntimeSessionID()
        let (state, effects) = run([
            .recoveryReported(.clean),
            .openCompleted,
            .spawnRequested(first),
            .spawnRecorded(first),
            .handshakeSucceeded(first),
            .spawnRequested(second),
            .spawnRecorded(second),
            .handshakeSucceeded(second),
            .cancelRequested(first),
            .runtimeExited(first),
            .closeRequested(publish: true),
            .runtimeExited(second),
            .closeSucceeded(published: true),
        ])
        #expect(effects[0] == [.establishBoundary])
        #expect(effects[8] == [.stopRuntime(first)])
        #expect(effects[10].last == .finishTeardown(publish: true))
        #expect(effects[12].last == .replyClosed(published: true))
        #expect(state.phase == .closed)
        #expect(state.publishCount == 1)
        #expect(state.runtimes[first] == .exited)
        #expect(state.runtimes[second] == .exited)
    }
}
