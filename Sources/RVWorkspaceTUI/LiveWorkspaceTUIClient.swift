#if os(macOS)
import Foundation
import Dispatch
import RVDomain
import RVIsolation

/// `WorkspaceClient` adapted to the TUI. This type never sees a PTY descriptor.
public final class LiveWorkspaceTUIClient: WorkspaceTUIClient, @unchecked Sendable {
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

    public func describe() -> Result<WorkspaceTUISummary, WorkspaceTUIClientError> {
        controlClient.describe().map { description in
            WorkspaceTUISummary(
                project: description.project,
                phase: description.phase.rawValue,
                protected: description.phase == .active,
                workspace: description.workspace
            )
        }.mapError(Self.failure)
    }

    public func listRuntimes() -> Result<[ListedRuntime], WorkspaceTUIClientError> {
        controlClient.listRuntimes().map { reports in
            reports.map {
                ListedRuntime(
                    id: $0.runtime,
                    hook: $0.hook,
                    running: $0.running,
                    terminal: $0.terminal,
                    rows: $0.rows,
                    columns: $0.columns
                )
            }
        }.mapError(Self.failure)
    }

    public func launchRuntime(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIClientError> {
        let host = hook.flatMap(HookHost.init(rawValue:))
        return controlClient.launchRuntime(
            executable: executable,
            arguments: arguments,
            hookHost: host,
            terminalRows: rows,
            terminalColumns: columns
        ).map { report in
            ListedRuntime(
                id: report.runtime,
                hook: report.hook,
                running: report.running,
                terminal: report.terminal,
                rows: report.rows,
                columns: report.columns
            )
        }.mapError(Self.failure)
    }

    public func cancelRuntime(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        controlClient.cancelRuntime(id).mapError(Self.failure)
    }

    public func subscribe(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        terminalClient.subscribeTerminal(id).mapError(Self.failure)
    }

    public func unsubscribe(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        terminalClient.unsubscribeTerminal(id).mapError(Self.failure)
    }

    public func acquireInput(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        terminalClient.acquireTerminalInput(id).mapError(Self.failure)
    }

    public func releaseInput(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        terminalClient.releaseTerminalInput(id).mapError(Self.failure)
    }

    public func write(_ id: UUID, bytes: Data) -> Result<Void, WorkspaceTUIClientError> {
        terminalClient.writeTerminal(id, bytes: bytes).mapError(Self.failure)
    }

    public func resize(_ id: UUID, rows: Int, columns: Int) -> Result<Void, WorkspaceTUIClientError> {
        terminalClient.resizeTerminal(id, rows: rows, columns: columns).mapError(Self.failure)
    }

    public func detach() -> Result<Void, WorkspaceTUIClientError> {
        let terminalResult = terminalClient.detach().mapError(Self.failure)
        let controlResult = controlClient.detach().mapError(Self.failure)
        if case .failure(let error) = terminalResult { return .failure(error) }
        return controlResult
    }

    public func nextEvent(timeout: TimeInterval) -> Result<WorkspaceTUIEvent?, WorkspaceTUIClientError> {
        switch terminalClient.nextTerminalEvent(timeout: timeout) {
        case .failure(let error):
            return .failure(Self.failure(error))
        case .success(.waiting):
            return .success(nil)
        case .success(.event(let event)):
            return .success(Self.event(event))
        }
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

    private static func failure(_ error: WorkspaceClientFailure) -> WorkspaceTUIClientError {
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

/// One reader for every subscribed runtime. It batches events before touching the model.
public final class TerminalEventPump: @unchecked Sendable {
    private let client: any WorkspaceTUIClient
    private let model: WorkspaceTUIModel
    private let stopped = MutexFlag()
    private let lifecycle = NSLock()
    private let finished = DispatchGroup()
    private var started = false
    private var thread: Thread?

    public init(client: any WorkspaceTUIClient, model: WorkspaceTUIModel) {
        self.client = client
        self.model = model
    }

    public func start() {
        lifecycle.lock()
        guard started == false else {
            lifecycle.unlock()
            return
        }
        started = true
        finished.enter()
        let thread = Thread { [self] in
            defer { finished.leave() }
            self.loop()
        }
        thread.name = "rv-workspace-tui"
        self.thread = thread
        lifecycle.unlock()
        thread.start()
    }

    public func stop() {
        stopped.stop()
        lifecycle.lock()
        let shouldWait = started && thread !== Thread.current
        lifecycle.unlock()
        if shouldWait { finished.wait() }
    }

    private func loop() {
        var batch: [WorkspaceTUIEvent] = []
        var batchBytes = 0
        while stopped.isStopped == false {
            switch client.nextEvent(timeout: 0.016) {
            case .failure:
                flush(&batch)
                model.hostDisconnected()
                return
            case .success(nil):
                flush(&batch)
                batchBytes = 0
            case .success(let event?):
                let eventBytes: Int
                if case .bytes(_, let data) = event { eventBytes = data.count }
                else { eventBytes = 0 }
                if batch.isEmpty == false && batchBytes + eventBytes > Self.maximumBatchBytes {
                    flush(&batch)
                    batchBytes = 0
                }
                batch.append(event)
                batchBytes += eventBytes
                if batch.count >= Self.maximumBatchEvents || batchBytes >= Self.maximumBatchBytes {
                    flush(&batch)
                    batchBytes = 0
                }
            }
        }
        flush(&batch)
    }

    private static let maximumBatchEvents = 64
    private static let maximumBatchBytes = 64 * 1024

    private func flush(_ batch: inout [WorkspaceTUIEvent]) {
        guard batch.isEmpty == false else { return }
        let copy = batch
        batch.removeAll(keepingCapacity: true)
        model.apply(copy)
    }
}

private final class MutexFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }
}
#endif
