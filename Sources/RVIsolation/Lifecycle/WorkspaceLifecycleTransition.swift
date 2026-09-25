import Foundation
import RVDomain

/// Pure workspace lifecycle decisions: `(State, Event) -> (State, Effects)`.
///
/// Every branch mirrors the current supervisor behavior, including which
/// failures are retryable and which completions drain to no-ops. The
/// transition never touches a process, a lock, a queue, or the filesystem.
///
/// Named `WorkspaceLifecycleTransition` (rather than `WorkspaceTransition`)
/// because `RVDomain.WorkspaceTransition` already names the three domain
/// phase moves; T7 reconciles the two when the supervisors rewire.
public enum WorkspaceLifecycleTransition {
    public static func transition(
        state: WorkspaceSupervisorState,
        event: WorkspaceEvent
    ) -> (state: WorkspaceSupervisorState, effects: WorkspaceEffects) {
        var next = state
        var effects: [WorkspaceEffect] = []
        switch event {
        case .recoveryReported(let outcome):
            // Admission reports once per open attempt; a second report is a
            // stale completion and drains.
            guard next.phase == .creating, next.admissionPending else { break }
            next.admissionPending = false
            switch outcome {
            case .clean, .recovered:
                effects = [.establishBoundary]
            case .liveOwner, .recoveryInProgress, .blocked, .interrupted, .failed:
                // Terminal for this attempt: nothing runs, nothing publishes.
                // A `.failed`/`.interrupted` outcome lets the opener retry
                // with a fresh state.
                next.phase = .closed
                effects = [.replyOpenRefused(outcome), .releaseOwnership]
            }

        case .openCompleted:
            guard next.phase == .creating else { break }
            next.admissionPending = false
            next.phase = .active

        case .openFailed:
            guard next.phase == .creating else { break }
            next.admissionPending = false
            next.phase = .closed
            effects = [.discardWorkspace, .releaseOwnership]

        case .spawnRequested(let id):
            guard next.phase == .active, next.closeAccepted == false else {
                effects = [.replySpawnRefused(id, .notAccepting(next.phase))]
                break
            }
            guard next.runtimes[id] == nil else { break }
            guard next.boundaryEstablished else {
                effects = [.replySpawnRefused(id, .boundaryLost)]
                break
            }
            if let limit = next.runningLimit,
                next.runningRuntimeIDs.count >= limit
            {
                effects = [.replySpawnRefused(id, .limitReached)]
                break
            }
            next.runtimes[id] = .starting
            effects = [.spawnRuntime(id)]

        case .spawnRecorded(let id):
            guard next.runtimes[id] == .starting else { break }
            next.runtimes[id] = .handshaking
            effects = [.resumeRuntime(id)]

        case .spawnFailed(let id):
            guard next.runtimes[id] == .starting else { break }
            next.runtimes[id] = nil
            effects = [.appendRuntimeEnded(id)]

        case .handshakeSucceeded(let id):
            guard next.runtimes[id] == .handshaking else { break }
            next.runtimes[id] = .established

        case .handshakeFailed(let id):
            guard next.runtimes[id] == .handshaking else { break }
            next.runtimes[id] = .failed
            effects = [.appendRuntimeEnded(id)]

        case .cancelRequested(let id):
            // Outside active/closing there is no table to cancel from.
            guard next.phase == .active || next.phase == .closing else {
                effects = [.replyUnknownRuntime(id)]
                break
            }
            guard let phase = next.runtimes[id] else {
                effects = [.replyUnknownRuntime(id)]
                break
            }
            switch phase {
            case .starting, .handshaking, .established, .exiting:
                next.runtimes[id] = .exiting
                effects = [.stopRuntime(id)]
            case .exited, .failed:
                effects = [.replyCancelled(id)]
            }

        case .runtimeExited(let id):
            guard let phase = next.runtimes[id], phase.isRunning else { break }
            next.runtimes[id] = .exited
            effects = [.appendRuntimeEnded(id)]

        case .runtimeForgotten(let id):
            guard let phase = next.runtimes[id], phase.isRunning == false else { break }
            next.runtimes[id] = nil

        case .closeRequested(let publish):
            if let failure = next.terminalCloseFailure {
                effects = [.replyCloseFailed(failure)]
                break
            }
            switch next.phase {
            case .creating:
                effects = [.replyCloseRefused(next.phase)]
            case .active:
                next.phase = .closing
                next.closeAccepted = true
                next.closePublish = publish
                next.teardownInFlight = true
                effects = next.runningRuntimeIDs.map { .stopRuntime($0) }
                effects.append(.finishTeardown(publish: publish))
            case .closing:
                // A close is already leading teardown; join it. After a
                // retryable `.childrenAlive` failure no teardown is in
                // flight, so this request leads with its own publish flag.
                guard next.teardownInFlight == false else {
                    effects = [.awaitClose]
                    break
                }
                next.closeAccepted = true
                next.closePublish = publish
                next.teardownInFlight = true
                effects = next.runningRuntimeIDs.map { .stopRuntime($0) }
                effects.append(.finishTeardown(publish: publish))
            case .closed:
                effects = [.replyAlreadyClosed]
            }

        case .closeSucceeded(let published):
            guard next.phase == .closing, next.teardownInFlight else { break }
            next.teardownInFlight = false
            next.phase = .closed
            if published {
                next.publishCount += 1
            }
            effects = [
                .appendClosed(published: published),
                .releaseOwnership,
                .replyClosed(published: published),
            ]

        case .closeFailed(let failure):
            guard next.phase == .closing, next.teardownInFlight else { break }
            next.teardownInFlight = false
            switch failure {
            case .childrenAlive:
                // Not cached as terminal: a later close may still publish.
                effects = [.replyCloseFailed(failure)]
            case .teardownFailed:
                next.terminalCloseFailure = failure
                effects = [.replyCloseFailed(failure)]
            }

        case .boundaryLost:
            next.boundaryEstablished = false

        case .controlReplyReceived(let id):
            // A reply that races an exit, names an unknown runtime, or
            // arrives after close drains; nothing is resurrected.
            guard next.phase != .closed,
                let phase = next.runtimes[id], phase.isRunning
            else { break }
            effects = [.forwardControlReply(id)]
        }
        return (next, WorkspaceEffects(effects))
    }
}
