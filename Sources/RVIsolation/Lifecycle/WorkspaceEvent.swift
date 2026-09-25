import Foundation
import RVDomain

/// Inputs the lifecycle transition decides on.
///
/// Open, spawn, watch, boundary, and close inputs share one enum so a
/// scripted event sequence fully determines the transitions without
/// spawning a process. Stray or duplicate inputs (a completion that races
/// an exit, a second close, a late control reply) reduce to no-ops.
public enum WorkspaceEvent: Sendable, Equatable {
    /// Recovery/admission reported for this open attempt.
    case recoveryReported(WorkspaceRecoveryOutcome)
    /// Boundary established and the `created` record is durable.
    case openCompleted
    /// Boundary, snapshot, or record setup failed during open.
    case openFailed
    /// A launch requests a runtime slot.
    case spawnRequested(RuntimeSessionID)
    /// The process was spawned and its group recorded.
    case spawnRecorded(RuntimeSessionID)
    /// Spawn, session record, or group registration failed.
    case spawnFailed(RuntimeSessionID)
    /// The in-sandbox handshake proved the runtime.
    case handshakeSucceeded(RuntimeSessionID)
    /// The handshake failed or the leader died unproven.
    case handshakeFailed(RuntimeSessionID)
    /// Stop one runtime; the workspace stays mounted.
    case cancelRequested(RuntimeSessionID)
    /// The watch reaped a runtime.
    case runtimeExited(RuntimeSessionID)
    /// Forget a finished runtime so reports stay bounded.
    case runtimeForgotten(RuntimeSessionID)
    /// Stop every runtime, then publish or discard the workspace.
    case closeRequested(publish: Bool)
    /// Teardown finished and the workspace was restored.
    case closeSucceeded(published: Bool)
    /// Teardown failed; see `WorkspaceCloseFailure`.
    case closeFailed(WorkspaceCloseFailure)
    /// `WorkspaceInodeBoundary.remainsEstablished()` turned false.
    case boundaryLost
    /// A control reply arrived for a runtime.
    case controlReplyReceived(RuntimeSessionID)
}

/// Why teardown failed.
///
/// Only `.childrenAlive` (today's `childTeardownFailed`) leaves the close
/// retryable: a later close may still publish. Any other teardown loss is
/// terminal and replayed to later closes without new work.
public enum WorkspaceCloseFailure: Sendable, Equatable {
    /// A child process group was still alive; nothing was published.
    case childrenAlive
    /// Publish, detach, restore, or the `closed` record failed.
    case teardownFailed
}
