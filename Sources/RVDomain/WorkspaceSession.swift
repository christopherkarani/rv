import Foundation

/// Identifier RV mints for one protected workspace.
///
/// This is not `RuntimeSessionID` and not hook `SessionID`. `init()` always
/// mints a new value. A path, a volume name, or a UUID chosen by an agent
/// cannot become a workspace id.
public struct WorkspaceSessionID: Hashable, Sendable, Equatable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }
}

/// Closed lifetime of one protected workspace.
///
/// A runtime may start only while the phase is `active`. Closing and closed
/// refuse new runtimes. There is no transition back to active.
public enum WorkspaceLifecycle: String, Sendable, Equatable, Codable {
    case creating
    case active
    case closing
    case closed

    public var acceptsRuntime: Bool {
        self == .active
    }

    public func transition(_ event: WorkspaceTransition) -> WorkspaceLifecycle? {
        switch (self, event) {
        case (.creating, .becameActive):
            .active
        case (.active, .beginClose):
            .closing
        case (.closing, .becameClosed):
            .closed
        default:
            nil
        }
    }
}

/// Legal moves on `WorkspaceLifecycle`. Anything else is refused.
public enum WorkspaceTransition: Sendable, Equatable {
    case becameActive
    case beginClose
    case becameClosed
}

/// Immutable snapshot of one protected workspace.
///
/// This value does not own a volume, a process, or an admission channel.
/// `WorkspaceSessionSupervisor` is the only owner of that lifetime.
public struct RVWorkspaceSession: Sendable, Equatable {
    public let id: WorkspaceSessionID
    /// Canonical project path the operator named.
    public let originalPath: WorkingDirectory
    /// Path the contained runtimes use. While the volume is mounted this is
    /// the same path as `originalPath`.
    public let protectedPath: WorkingDirectory
    public let createdAt: Date
    public let phase: WorkspaceLifecycle
    /// Workspace identity admission and later policy read. Not a second root.
    public let policyWorkspace: WorkingDirectory

    public init(
        id: WorkspaceSessionID,
        originalPath: WorkingDirectory,
        protectedPath: WorkingDirectory,
        createdAt: Date,
        phase: WorkspaceLifecycle,
        policyWorkspace: WorkingDirectory
    ) {
        self.id = id
        self.originalPath = originalPath
        self.protectedPath = protectedPath
        self.createdAt = createdAt
        self.phase = phase
        self.policyWorkspace = policyWorkspace
    }
}
