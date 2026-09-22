import Foundation

/// Backend family for a contained runtime session.
/// Observed and mediated launches are not sessions.
public enum RuntimeIsolationBackend: String, Sendable, Equatable {
    case seatbelt
    case landlock
}

/// Immediate child of an RV contained launch, recorded after spawn.
/// A pid is not a capability and is not accepted as a launch request.
public struct RuntimeChildIdentity: Hashable, Sendable, Equatable {
    public let pid: Int32

    public init(pid: Int32) {
        self.pid = pid
    }
}

/// Durable identity of one contained execution.
///
/// This is domain state. It does not own a process, a pipe, or a sandbox
/// profile. The supervisor that starts and stops the process lives in
/// RVIsolation.
public struct RuntimeSession: Sendable, Equatable {
    public let id: RuntimeSessionID
    public let host: HookHost?
    public let workspace: WorkingDirectory
    public let backend: RuntimeIsolationBackend
    public let startedAt: Date
    public let child: RuntimeChildIdentity?

    public init(
        id: RuntimeSessionID,
        host: HookHost?,
        workspace: WorkingDirectory,
        backend: RuntimeIsolationBackend,
        startedAt: Date,
        child: RuntimeChildIdentity?
    ) {
        self.id = id
        self.host = host
        self.workspace = workspace
        self.backend = backend
        self.startedAt = startedAt
        self.child = child
    }

    public func withChild(pid: Int32) -> RuntimeSession {
        RuntimeSession(
            id: id,
            host: host,
            workspace: workspace,
            backend: backend,
            startedAt: startedAt,
            child: RuntimeChildIdentity(pid: pid)
        )
    }
}
