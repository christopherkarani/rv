#if os(macOS)
import Foundation
import RVDomain
import RVIsolation
import Synchronization

/// `WorkspaceClient` adapted to the TUI. This type never sees a PTY descriptor.
public final class LiveWorkspaceTUISession: WorkspaceTUISession {
    private struct Connections {
        /// Lifecycle and subscription traffic has its own host connection. A
        /// cancellation can wait for child teardown, so terminal input must not
        /// share that ordered server request loop.
        var control: WorkspaceClient
        /// Terminal subscriptions/events and lease, write, and resize RPCs use one
        /// independent host connection. It never carries lifecycle cancellation.
        var terminal: WorkspaceClient
        var endpoint: WorkspaceEndpoint?
        var closed = false
    }

    /// Guards only the connection refs; every RPC runs on a copied ref outside the lock.
    private let connections: Mutex<Connections>
    private let project: String?
    private let hostExecutable: URL?

    private var controlClient: WorkspaceClient {
        connections.withLock { $0.control }
    }

    private var terminalClient: WorkspaceClient {
        connections.withLock { $0.terminal }
    }

    public init(controlClient: WorkspaceClient, terminalClient: WorkspaceClient,
                endpoint: WorkspaceEndpoint? = nil, project: String? = nil,
                hostExecutable: URL? = nil) {
        precondition(controlClient !== terminalClient, "workspace TUI requires separate control and terminal clients")
        self.connections = Mutex(Connections(
            control: controlClient, terminal: terminalClient, endpoint: endpoint
        ))
        self.project = project
        self.hostExecutable = hostExecutable
    }

    /// Opens the paired control and terminal connections. A half-opened pair
    /// is detached before returning the failure.
    public static func connect(_ endpoint: WorkspaceEndpoint, project: String? = nil,
                               hostExecutable: URL? = nil) -> Result<LiveWorkspaceTUISession, WorkspaceClientFailure> {
        connectPair(endpoint).map { pair in
            LiveWorkspaceTUISession(
                controlClient: pair.control, terminalClient: pair.terminal,
                endpoint: endpoint, project: project, hostExecutable: hostExecutable
            )
        }
    }

    public func reconnect() -> Result<Void, WorkspaceTUIError> {
        let target: WorkspaceEndpoint
        if let project, let hostExecutable {
            switch WorkspaceHosts.ensure(project: project, executable: hostExecutable, timeout: 15) {
            case .success(let endpoint):
                target = endpoint
            case .failure(.control(.incompatibleProtocol)):
                return .failure(.incompatibleHost)
            case .failure:
                return .failure(.disconnected)
            }
        } else {
            guard let previous = connections.withLock({ $0.endpoint }) else { return .failure(.disconnected) }
            target = previous
        }
        let pair: (control: WorkspaceClient, terminal: WorkspaceClient)
        switch Self.connectPair(target) {
        case .success(let connected): pair = connected
        case .failure(let error): return .failure(Self.failure(error))
        }
        let old = connections.withLock { state -> (control: WorkspaceClient, terminal: WorkspaceClient)? in
            if state.closed { return nil }
            let replaced = (control: state.control, terminal: state.terminal)
            state.control = pair.control
            state.terminal = pair.terminal
            state.endpoint = target
            return replaced
        }
        guard let old else {
            _ = pair.terminal.detach()
            _ = pair.control.detach()
            return .failure(.disconnected)
        }
        _ = old.terminal.detach()
        _ = old.control.detach()
        return .success(())
    }

    /// Opens control then terminal; a half-opened pair detaches control
    /// before returning the failure.
    private static func connectPair(
        _ endpoint: WorkspaceEndpoint
    ) -> Result<(control: WorkspaceClient, terminal: WorkspaceClient), WorkspaceClientFailure> {
        switch WorkspaceClient.connect(endpoint) {
        case .failure(let error):
            return .failure(error)
        case .success(let control):
            switch WorkspaceClient.connect(endpoint) {
            case .failure(let error):
                _ = control.detach()
                return .failure(error)
            case .success(let terminal):
                return .success((control: control, terminal: terminal))
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

    /// A failed subscribe reports `unavailable` without acquiring. Acquiring a
    /// lease for a runtime this session is not subscribed to would leave an
    /// orphaned lease the model cannot observe events for, so unlike the
    /// pre-seam model (which attempted an acquire after any non-disconnect
    /// subscribe failure) this pairing stops before the acquire.
    public func attach(_ id: UUID) -> SessionAttachOutcome {
        switch observe(id) {
        case .readOnly:
            return acquire(id)
        case .disconnected:
            return .disconnected
        case .unavailable:
            return .unavailable
        case .owned:
            return .owned
        }
    }

    public func observe(_ id: UUID) -> SessionAttachOutcome {
        switch terminalClient.subscribeTerminal(id) {
        case .success:
            return .readOnly
        case .failure(.disconnected), .failure(.workspaceClosed), .failure(.staleEndpoint):
            return .disconnected
        case .failure:
            return .unavailable
        }
    }

    public func resubscribe(_ id: UUID) -> SessionAttachOutcome {
        switch terminalClient.resubscribeTerminal(id) {
        case .success:
            return acquire(id)
        case .failure(.disconnected), .failure(.workspaceClosed), .failure(.staleEndpoint):
            return .disconnected
        case .failure:
            return .unavailable
        }
    }

    public func reacquire(_ id: UUID) -> SessionAttachOutcome {
        // Unlike attach()'s acquire, this preserves "no subscription" (a
        // silent overflow drop, or a gone runtime) instead of folding it
        // into contention, so the TUI can resubscribe and recover.
        switch terminalClient.acquireTerminalInput(id) {
        case .success:
            return .owned
        case .failure(.disconnected), .failure(.workspaceClosed), .failure(.staleEndpoint):
            return .disconnected
        case .failure(.terminalUnavailable), .failure(.runtimeNotFound):
            return .unavailable
        case .failure:
            return .readOnly
        }
    }

    public func releaseInput(_ id: UUID) -> Result<Void, WorkspaceTUIError> {
        terminalClient.releaseTerminalInput(id).mapError(Self.failure)
    }

    /// A malformed hook tag is rejected. Silently dropping it to `nil`
    /// would ensure an untagged runtime the launcher cannot title or match.
    /// Step 8 (F2): only the HookHost part travels; a tag that names no
    /// host selects nothing, and tags never stage credentials.
    public func ensureTerminal(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int,
        resourceProfileID: String?
    ) -> Result<ListedRuntime, WorkspaceTUIError> {
        if let hook, AgentTagValidator.isValid(hook) == false {
            return .failure(.rejected)
        }
        return controlClient.ensureTerminalRuntime(
            executable: executable,
            arguments: arguments,
            hookHost: hook.flatMap(HookHost.init(rawValue:)),
            terminalRows: rows,
            terminalColumns: columns,
            resourceProfileID: resourceProfileID
        ).map(Self.listed).mapError(Self.failure)
    }

    /// A malformed hook tag is rejected. Silently dropping it to `nil`
    /// would launch an untagged runtime the launcher cannot title or match.
    public func launch(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIError> {
        launch(executable: executable, arguments: arguments, hook: hook,
               rows: rows, columns: columns, resourceProfileID: nil)
    }

    public func launch(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int,
        resourceProfileID: String?
    ) -> Result<ListedRuntime, WorkspaceTUIError> {
        if let hook, AgentTagValidator.isValid(hook) == false {
            return .failure(.rejected)
        }
        return controlClient.launchRuntime(
            executable: executable,
            arguments: arguments,
            hookHost: hook.flatMap(HookHost.init(rawValue:)),
            terminalRows: rows,
            terminalColumns: columns,
            resourceProfileID: resourceProfileID
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
        guard let chunks = TerminalInputChunks.make(bytes) else { return .failure(.rejected) }
        for chunk in chunks {
            if case .failure(let error) = terminalClient.writeTerminal(id, bytes: chunk) {
                return .failure(Self.failure(error))
            }
        }
        return .success(())
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
        let (terminal, control) = connections.withLock { state in
            state.closed = true
            return (state.terminal, state.control)
        }
        _ = terminal.detach()
        _ = control.detach()
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
        case .replayBegin(let batch, let truncated, let byteCount):
            .replayBegin(runtime: event.runtime, batch: batch,
                         truncated: truncated, byteCount: byteCount)
        case .replayEnd(let batch):
            .replayEnd(runtime: event.runtime, batch: batch)
        case .replay(_, let bytes), .output(_, let bytes):
            .bytes(runtime: event.runtime, data: bytes)
        case .overflow:
            .overflow(runtime: event.runtime)
        case .exited(let status):
            .exited(runtime: event.runtime, status: status)
        case .inputOwner(let owned):
            .inputOwner(runtime: event.runtime, owned: owned)
        case .window(let rows, let columns):
            .window(runtime: event.runtime, rows: rows, columns: columns)
        }
    }

    private static func failure(_ error: WorkspaceClientFailure) -> WorkspaceTUIError {
        switch error {
        case .incompatibleProtocol:
            .incompatibleHost
        case .disconnected, .workspaceClosed, .staleEndpoint:
            .disconnected
        case .terminalBusy:
            .busy
        case .terminalUnavailable, .runtimeNotFound:
            .unavailable
        case .resourceProfileUnavailable:
            .resourceProfileUnavailable
        case .resourceStagingFailed(let detail):
            .resourceStagingFailed(detail)
        default:
            .rejected
        }
    }
}
#endif
