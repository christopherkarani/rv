import Foundation
import RVDomain

/// One supervisor action for the runtime to execute. Effects never dispatch
/// themselves; the supervisor owns lock discipline and thread choice.
public enum WorkspaceEffect: Sendable, Equatable {
    /// Establish the inode boundary for an admitted open.
    case establishBoundary
    /// Release ownership (registry entry and owner lock).
    case releaseOwnership
    /// Discard the private volume and restore the original path.
    case discardWorkspace
    /// Refuse an open attempt; the outcome tells the opener the reason.
    case replyOpenRefused(WorkspaceRecoveryOutcome)
    /// Spawn and record one runtime process.
    case spawnRuntime(RuntimeSessionID)
    /// Resume a recorded runtime and claim its foreground group.
    case resumeRuntime(RuntimeSessionID)
    /// Signal one runtime's process group to stop.
    case stopRuntime(RuntimeSessionID)
    /// Run teardown: wait out the group, then publish or discard.
    case finishTeardown(publish: Bool)
    /// Join the close already in flight instead of leading a new one.
    case awaitClose
    /// Refuse a spawn; the reason maps to today's session errors.
    case replySpawnRefused(RuntimeSessionID, WorkspaceSpawnRefusal)
    /// The named runtime is unknown in this phase.
    case replyUnknownRuntime(RuntimeSessionID)
    /// The named runtime is already gone; cancel succeeds.
    case replyCancelled(RuntimeSessionID)
    /// The workspace is already closed.
    case replyAlreadyClosed
    /// Close is not accepted in this phase.
    case replyCloseRefused(WorkspaceLifecycle)
    /// Teardown failed; retryable only for `.childrenAlive`.
    case replyCloseFailed(WorkspaceCloseFailure)
    /// The workspace closed.
    case replyClosed(published: Bool)
    /// Append a `runtimeEnded` lifecycle record.
    case appendRuntimeEnded(RuntimeSessionID)
    /// Append the `closed` lifecycle record.
    case appendClosed(published: Bool)
    /// Deliver a control reply to a running runtime.
    case forwardControlReply(RuntimeSessionID)
}

/// Why a spawn was refused without starting a process.
public enum WorkspaceSpawnRefusal: Sendable, Equatable {
    /// The phase does not accept runtimes (close accepted or not active).
    case notAccepting(WorkspaceLifecycle)
    /// The concurrent running-runtime cap is full.
    case limitReached
    /// The inode boundary no longer holds.
    case boundaryLost
}

/// The spawned work, log appends, and replies one transition emits.
public struct WorkspaceEffects: Sendable, Equatable {
    public var effects: [WorkspaceEffect]

    public init(_ effects: [WorkspaceEffect] = []) {
        self.effects = effects
    }

    public static var none: Self { Self([]) }
}
