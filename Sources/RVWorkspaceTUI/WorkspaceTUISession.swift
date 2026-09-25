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

public enum WorkspaceTUIError: Error, Equatable, Sendable {
    case disconnected
    case busy
    case unavailable
    case rejected
}

/// One inventory call: the workspace summary plus its terminal runtimes,
/// filtered and sorted by id. The model attaches to `terminals.first`.
public struct SessionInventory: Equatable, Sendable {
    public var summary: WorkspaceTUISummary
    public var terminals: [ListedRuntime]

    public init(summary: WorkspaceTUISummary, terminals: [ListedRuntime]) {
        self.summary = summary
        self.terminals = terminals
    }
}

/// The outcome of pairing a subscription with an input-lease acquire.
/// A contended lease is `readOnly`, not a failure: the terminal renders and
/// the model retries the lease when the host reports it free.
public enum SessionAttachOutcome: Equatable, Sendable {
    case owned
    case readOnly
    case unavailable
    case disconnected
}

public enum SessionPoll: Equatable, Sendable {
    case event(WorkspaceTUIEvent)
    case none
    case disconnected
}

/// The only path from the TUI to a workspace. Production wraps two host
/// connections (control and terminal); the pairing, the subscribe/acquire and
/// release/unsubscribe coupling, and error collapse all live behind this seam.
/// Every method is a blocking host RPC; the model serializes calls on its own
/// command and terminal queues.
public protocol WorkspaceTUISession: AnyObject, Sendable {
    func inventory() -> Result<SessionInventory, WorkspaceTUIError>
    /// Subscribes to the runtime, then acquires its input lease. A failed
    /// subscribe reports `unavailable` without acquiring.
    func attach(_ id: UUID) -> SessionAttachOutcome
    /// Acquires the input lease for an already-subscribed runtime. The host
    /// rejects a second subscribe, so lease retries must not re-attach.
    /// Never reports `unavailable`; a failed acquire degrades to `readOnly`.
    func reacquire(_ id: UUID) -> SessionAttachOutcome
    func ensureTerminal(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIError>
    func launch(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIError>
    func cancel(_ id: UUID)
    /// Releases the input lease, then unsubscribes. Best-effort: releasing a
    /// lease this session never owned succeeds.
    func release(_ id: UUID)
    /// A contended write reports `busy` so the model can render read-only;
    /// other failures stay visible so the model can ignore them.
    func send(_ bytes: Data, to id: UUID) -> Result<Void, WorkspaceTUIError>
    func resize(_ id: UUID, rows: Int, columns: Int) -> Result<Void, WorkspaceTUIError>
    func poll(timeout: TimeInterval) -> SessionPoll
    func close()
}

/// One reader for the attached runtime. It batches polls before touching the
/// model. The model owns this pump: it starts on `startEventDelivery` and
/// stops inside `detachSession`.
final class SessionEventPump: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var thread: Thread?
    private let finished = DispatchGroup()

    func start(
        session: any WorkspaceTUISession,
        onEvents: @escaping @Sendable ([WorkspaceTUIEvent]) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        guard started == false else {
            lock.unlock()
            return
        }
        started = true
        finished.enter()
        let thread = Thread { [weak self] in
            defer { self?.finished.leave() }
            self?.loop(session: session, onEvents: onEvents, onDisconnect: onDisconnect)
        }
        thread.name = "rv-workspace-tui"
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let shouldWait = started && thread !== Thread.current
        lock.unlock()
        if shouldWait { finished.wait() }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func loop(
        session: any WorkspaceTUISession,
        onEvents: @escaping @Sendable ([WorkspaceTUIEvent]) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) {
        var batch: [WorkspaceTUIEvent] = []
        var batchBytes = 0
        while isStopped() == false {
            switch session.poll(timeout: 0.016) {
            case .disconnected:
                flush(&batch, to: onEvents)
                onDisconnect()
                return
            case .none:
                flush(&batch, to: onEvents)
                batchBytes = 0
            case .event(let event):
                let eventBytes: Int
                if case .bytes(_, let data) = event { eventBytes = data.count }
                else { eventBytes = 0 }
                if batch.isEmpty == false && batchBytes + eventBytes > Self.maximumBatchBytes {
                    flush(&batch, to: onEvents)
                    batchBytes = 0
                }
                batch.append(event)
                batchBytes += eventBytes
                if batch.count >= Self.maximumBatchEvents || batchBytes >= Self.maximumBatchBytes {
                    flush(&batch, to: onEvents)
                    batchBytes = 0
                }
            }
        }
        flush(&batch, to: onEvents)
    }

    private static let maximumBatchEvents = 64
    private static let maximumBatchBytes = 64 * 1024

    private func flush(
        _ batch: inout [WorkspaceTUIEvent],
        to onEvents: @escaping @Sendable ([WorkspaceTUIEvent]) -> Void
    ) {
        guard batch.isEmpty == false else { return }
        let copy = batch
        batch.removeAll(keepingCapacity: true)
        onEvents(copy)
    }
}
