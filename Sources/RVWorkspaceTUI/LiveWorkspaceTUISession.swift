#if os(macOS)
import Foundation
import RVDomain
import RVIsolation

/// `WorkspaceClient` adapted to the TUI. This type never sees a PTY descriptor.
public final class LiveWorkspaceTUISession: WorkspaceTUISession, @unchecked Sendable {
    /// Lifecycle and subscription traffic has its own host connection. A
    /// cancellation can wait for child teardown, so terminal input must not
    /// share that ordered server request loop.
    private let controlClient: WorkspaceClient
    /// Terminal subscriptions/events and lease, write, and resize RPCs use one
    /// independent host connection. It never carries lifecycle cancellation.
    private let terminalClient: WorkspaceClient

    public init(controlClient: WorkspaceClient, terminalClient: WorkspaceClient) {
        precondition(controlClient !== terminalClient, "workspace TUI requires separate control and terminal clients")
        self.controlClient = controlClient
        self.terminalClient = terminalClient
    }

    /// Opens the paired control and terminal connections. A half-opened pair
    /// is detached before returning the failure.
    public static func connect(_ endpoint: WorkspaceEndpoint) -> Result<LiveWorkspaceTUISession, WorkspaceClientFailure> {
        switch WorkspaceClient.connect(endpoint) {
        case .failure(let error):
            return .failure(error)
        case .success(let control):
            switch WorkspaceClient.connect(endpoint) {
            case .failure(let error):
                _ = control.detach()
                return .failure(error)
            case .success(let terminal):
                return .success(LiveWorkspaceTUISession(controlClient: control, terminalClient: terminal))
            }
        }
    }

    public func inventory() -> Result<SessionInventory, WorkspaceTUIError> {
        let summary: WorkspaceTUISummary
        switch controlClient.describe() {
        case .success(let description):
            summary = WorkspaceTUISummary(
                project: description.project,
                phase: description.phase.rawValue,
                protected: description.phase == .active,
                workspace: description.workspace
            )
        case .failure(let error):
            return .failure(Self.failure(error))
        }
        switch controlClient.listRuntimes() {
        case .success(let reports):
            let terminals = reports
                .filter(\.terminal)
                .sorted { $0.runtime.uuidString < $1.runtime.uuidString }
                .map(Self.listed)
            return .success(SessionInventory(summary: summary, terminals: terminals))
        case .failure(let error):
            return .failure(Self.failure(error))
        }
    }

    public func attach(_ id: UUID) -> SessionAttachOutcome {
        switch terminalClient.subscribeTerminal(id) {
        case .success:
            break
        case .failure(.disconnected), .failure(.workspaceClosed), .failure(.staleEndpoint):
            return .disconnected
        case .failure:
            return .unavailable
        }
        return acquire(id)
    }

    public func reacquire(_ id: UUID) -> SessionAttachOutcome {
        acquire(id)
    }

    public func ensureTerminal(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIError> {
        controlClient.ensureTerminalRuntime(
            executable: executable,
            arguments: arguments,
            hookHost: hook.flatMap(HookHost.init(rawValue:)),
            terminalRows: rows,
            terminalColumns: columns
        ).map(Self.listed).mapError(Self.failure)
    }

    public func launch(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIError> {
        controlClient.launchRuntime(
            executable: executable,
            arguments: arguments,
            hookHost: hook.flatMap(HookHost.init(rawValue:)),
            terminalRows: rows,
            terminalColumns: columns
        ).map(Self.listed).mapError(Self.failure)
    }

    public func cancel(_ id: UUID) {
        _ = controlClient.cancelRuntime(id)
    }

    public func release(_ id: UUID) {
        _ = terminalClient.releaseTerminalInput(id)
        _ = terminalClient.unsubscribeTerminal(id)
    }

    public func send(_ bytes: Data, to id: UUID) -> Result<Void, WorkspaceTUIError> {
        terminalClient.writeTerminal(id, bytes: bytes).mapError(Self.failure)
    }

    public func resize(_ id: UUID, rows: Int, columns: Int) -> Result<Void, WorkspaceTUIError> {
        terminalClient.resizeTerminal(id, rows: rows, columns: columns).mapError(Self.failure)
    }

    public func poll(timeout: TimeInterval) -> SessionPoll {
        switch terminalClient.nextTerminalEvent(timeout: timeout) {
        case .failure:
            return .disconnected
        case .success(.waiting):
            return .none
        case .success(.event(let event)):
            return .event(Self.event(event))
        }
    }

    public func close() {
        _ = terminalClient.detach()
        _ = controlClient.detach()
    }

    private func acquire(_ id: UUID) -> SessionAttachOutcome {
        switch terminalClient.acquireTerminalInput(id) {
        case .success:
            return .owned
        case .failure(.disconnected), .failure(.workspaceClosed), .failure(.staleEndpoint):
            return .disconnected
        case .failure:
            return .readOnly
        }
    }

    private static func listed(_ report: WorkspaceRuntimeReport) -> ListedRuntime {
        ListedRuntime(
            id: report.runtime,
            hook: report.hook,
            running: report.running,
            terminal: report.terminal,
            rows: report.rows,
            columns: report.columns,
            created: report.created
        )
    }

    private static func event(_ event: WorkspaceTerminalEvent) -> WorkspaceTUIEvent {
        switch event.body {
        case .replay(_, let bytes), .output(_, let bytes):
            .bytes(runtime: event.runtime, data: bytes)
        case .overflow:
            .overflow(runtime: event.runtime)
        case .exited(let status):
            .exited(runtime: event.runtime, status: status)
        case .inputOwner(let owned):
            .inputOwner(runtime: event.runtime, owned: owned)
        }
    }

    private static func failure(_ error: WorkspaceClientFailure) -> WorkspaceTUIError {
        switch error {
        case .disconnected, .workspaceClosed, .staleEndpoint:
            .disconnected
        case .terminalBusy:
            .busy
        case .terminalUnavailable, .runtimeNotFound:
            .unavailable
        default:
            .rejected
        }
    }
}
#endif
