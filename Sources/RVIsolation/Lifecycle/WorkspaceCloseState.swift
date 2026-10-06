import Foundation
import RVDomain

/// Whether a close publishes the workspace or discards it.
///
/// This is the close-level choice carried by `WorkspaceEvent.closeRequested`
/// and the teardown effects. It is distinct from `WorkspacePublishDecision`,
/// which is the per-file verdict used while publishing.
public enum WorkspaceClosePublish: Sendable, Equatable {
    /// Copy volume contents onto the original inodes.
    case publish
    /// Drop the volume; the original directory returns unchanged.
    case discard
}

/// Where this workspace's close stands.
///
/// One value replaces the old `closeAccepted`/`closePublish`/`teardownInFlight`
/// /`terminalCloseFailure` cluster, which permitted contradictory combinations
/// (teardown in flight with no accepted close, a publish flag with no owner,
/// a terminal failure on an active workspace). The transition is the only
/// writer; every case names a reachable moment in the close protocol.
public enum WorkspaceCloseState: Sendable, Equatable {
    /// No close has been accepted.
    case open
    /// This close leads teardown with its publish choice; no new runtime
    /// may start. A second close joins via `.awaitClose`.
    case leading(publish: WorkspaceClosePublish)
    /// Teardown failed retryably (`.childrenAlive`); the next close leads
    /// with its own publish choice.
    case waiting
    /// Teardown failed terminally; later closes replay the failure.
    case terminal(WorkspaceCloseFailure)
    /// Teardown finished and the workspace was restored.
    case finished(published: WorkspaceClosePublish)
}
