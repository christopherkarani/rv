import Foundation

public struct WorkspaceTUISummary: Equatable, Sendable {
    public var project: String
    public var phase: String
    public var protected: Bool
    public var workspace: UUID

    public init(project: String, phase: String, protected: Bool, workspace: UUID) {
        self.project = project
        self.phase = phase
        self.protected = protected
        self.workspace = workspace
    }
}

public struct ListedRuntime: Equatable, Sendable {
    public var id: UUID
    public var hook: String?
    public var running: Bool
    public var terminal: Bool
    public var rows: Int?
    public var columns: Int?
    public var created: Bool

    public init(
        id: UUID,
        hook: String?,
        running: Bool,
        terminal: Bool,
        rows: Int? = nil,
        columns: Int? = nil,
        created: Bool = false
    ) {
        self.id = id
        self.hook = hook
        self.running = running
        self.terminal = terminal
        self.rows = rows
        self.columns = columns
        self.created = created
    }
}

public enum WorkspaceTUIEvent: Equatable, Sendable {
    case bytes(runtime: UUID, data: Data)
    case overflow(runtime: UUID)
    case exited(runtime: UUID, status: Int32)
    case inputOwner(runtime: UUID, owned: Bool)
}

public enum WorkspaceTUIClientError: Error, Equatable, Sendable {
    case disconnected
    case busy
    case rejected
    case unavailable
}

/// The only path from the TUI to a workspace. Production wraps `WorkspaceClient`.
public protocol WorkspaceTUIClient: AnyObject, Sendable {
    func describe() -> Result<WorkspaceTUISummary, WorkspaceTUIClientError>
    func listRuntimes() -> Result<[ListedRuntime], WorkspaceTUIClientError>
    func launchRuntime(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIClientError>
    func ensureTerminalRuntime(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIClientError>
    func cancelRuntime(_ id: UUID) -> Result<Void, WorkspaceTUIClientError>
    func subscribe(_ id: UUID) -> Result<Void, WorkspaceTUIClientError>
    func unsubscribe(_ id: UUID) -> Result<Void, WorkspaceTUIClientError>
    func acquireInput(_ id: UUID) -> Result<Void, WorkspaceTUIClientError>
    func releaseInput(_ id: UUID) -> Result<Void, WorkspaceTUIClientError>
    func write(_ id: UUID, bytes: Data) -> Result<Void, WorkspaceTUIClientError>
    func resize(_ id: UUID, rows: Int, columns: Int) -> Result<Void, WorkspaceTUIClientError>
    func detach() -> Result<Void, WorkspaceTUIClientError>
    func nextEvent(timeout: TimeInterval) -> Result<WorkspaceTUIEvent?, WorkspaceTUIClientError>
}
