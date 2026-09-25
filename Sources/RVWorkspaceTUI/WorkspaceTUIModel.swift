import Foundation

/// Presentation state for one workspace shell.
///
/// Process groups, PTYs, capabilities, and recovery stay in the workspace host.
/// This model owns the one visible terminal, its render state, and
/// command-prefix mode. Panes and tabs are deferred: at most one runtime is
/// attached, and a later attach reuses the existing runtime inventory.
public final class WorkspaceTUIModel: @unchecked Sendable {
    private let session: any WorkspaceTUISession
    private let emulators: any TerminalEmulatorFactory
    private let lock = NSLock()
    /// Lifecycle RPCs use a separate Workspace Host connection. Cancellation
    /// can wait for child teardown without blocking terminal I/O.
    private let commandQueue = DispatchQueue(label: "rv.workspace-tui.commands")
    /// Lease, write, and resize RPCs share the session's independent terminal
    /// connection and stay ordered with each other.
    private let terminalQueue = DispatchQueue(label: "rv.workspace-tui.terminal")
    private var pump: SessionEventPump?
    private var terminal: WorkspaceTerminal?
    private var presentationRevision: UInt64 = 0
    private var mode: CommandMode = .terminal
    private var connection: ConnectionState = .disconnected
    private var summary: WorkspaceTUISummary
    private let launcher: [RuntimeLaunchChoice]
    private var shouldExit = false
    private var didConnect = false
    private var didDetach = false
    private var initialRuntimeLaunchRequested = false
    private var leasedRuntime: UUID?
    private var retryAcquire = false
    private var viewSize: (rows: Int, columns: Int)?
    private let initialRows: Int
    private let initialColumns: Int

    public init(
        session: any WorkspaceTUISession,
        emulators: any TerminalEmulatorFactory = SwiftTermFactory(),
        summary: WorkspaceTUISummary,
        launcher: [RuntimeLaunchChoice],
        rows: Int = 24,
        columns: Int = 80
    ) {
        self.session = session
        self.emulators = emulators
        self.summary = summary
        self.launcher = launcher
        self.initialRows = Self.bound(rows)
        self.initialColumns = Self.bound(columns)
    }

    /// Describes and inventories through the session. Repeated calls are
    /// harmless and never create another runtime.
    public func connect() -> Result<Void, WorkspaceTUIError> {
        lock.lock()
        if didConnect {
            let connected = connection == .connected
            lock.unlock()
            return connected ? .success(()) : .failure(.disconnected)
        }
        lock.unlock()

        let inventoried: SessionInventory
        switch session.inventory() {
        case .success(let value):
            inventoried = value
        case .failure(let error):
            markDisconnected()
            return .failure(error)
        }

        lock.lock()
        summary = inventoried.summary
        connection = .connected
        didConnect = true
        if let runtime = inventoried.terminals.first {
            let rows = runtime.rows.map(Self.bound) ?? initialRows
            let columns = runtime.columns.map(Self.bound) ?? initialColumns
            terminal = makeRecord(runtime: runtime, rows: rows, columns: columns)
        }
        markPresentationChangedLocked()
        let attached = terminal?.state.runtime
        lock.unlock()

        if let attached {
            switch session.attach(attached) {
            case .owned:
                noteAcquired(attached)
            case .readOnly:
                noteAttached(attached, lease: .readOnly)
            case .unavailable:
                noteUnattached(attached)
            case .disconnected:
                markDisconnected()
                return .failure(.disconnected)
            }
        }
        return .success(())
    }

    /// Starts the session's event reader. Idempotent; the reader stops inside
    /// `detachSession`. The app calls this once after `connect` succeeds.
    public func startEventDelivery() {
        lock.lock()
        if pump == nil {
            pump = SessionEventPump()
        }
        let pump = pump
        lock.unlock()
        pump?.start(
            session: session,
            onEvents: { [weak self] in self?.apply($0) },
            onDisconnect: { [weak self] in self?.hostDisconnected() }
        )
    }

    /// Establishes a host-owned terminal before the local terminal begins
    /// accepting input. The host serializes this operation across TUI clients.
    public func launchDefaultRuntimeIfEmpty() {
        lock.lock()
        guard didConnect, connection == .connected, didDetach == false, shouldExit == false,
              terminal == nil, initialRuntimeLaunchRequested == false else {
            lock.unlock()
            return
        }
        initialRuntimeLaunchRequested = true
        let shell = launcher.first { $0.id == "shell" }
        if shell == nil {
            mode = .launcher
            markPresentationChangedLocked()
        }
        lock.unlock()

        guard let shell else { return }

        let runtime: ListedRuntime
        switch session.ensureTerminal(
            executable: shell.executable,
            arguments: shell.arguments,
            hook: shell.hook,
            rows: initialRows,
            columns: initialColumns
        ) {
        case .success(let value):
            runtime = value
        case .failure(.disconnected):
            markDisconnected()
            return
        case .failure:
            lock.lock()
            if terminal == nil, connection == .connected {
                mode = .launcher
                markPresentationChangedLocked()
            }
            lock.unlock()
            return
        }

        let rows = runtime.rows.map(Self.bound) ?? initialRows
        let columns = runtime.columns.map(Self.bound) ?? initialColumns
        let title: String
        if let hook = runtime.hook {
            title = launcher.first(where: { $0.hook == hook })?.title ?? hook
        } else {
            title = runtime.created ? shell.title : "runtime"
        }
        lock.lock()
        guard terminal == nil, connection == .connected, didDetach == false, shouldExit == false else {
            lock.unlock()
            return
        }
        var record = makeRecord(runtime: runtime, rows: rows, columns: columns)
        record.state.title = title
        terminal = record
        markPresentationChangedLocked()
        lock.unlock()

        let outcome = session.attach(runtime.id)
        if outcome == .disconnected {
            markDisconnected()
        }
        switch outcome {
        case .owned:
            noteAcquired(runtime.id)
        case .readOnly:
            noteAttached(runtime.id, lease: .readOnly)
        case .unavailable, .disconnected:
            lock.lock()
            if terminal?.state.subscribed == false {
                terminal?.state.title = "\(title) (unavailable)"
                terminal?.state.lease = .readOnly
                markPresentationChangedLocked()
            }
            lock.unlock()
        }
    }

    public func handle(_ key: TUIKey, now: Date = Date()) {
        let command: TUICommand?
        lock.lock()
        guard didDetach == false, shouldExit == false else {
            lock.unlock()
            return
        }
        let previousMode = mode
        let previousShouldExit = shouldExit
        let decision = CommandPrefix.route(
            key,
            mode: mode,
            launcher: launcher,
            directLauncherSelection: terminal?.state.running != true
        )
        mode = decision.0
        command = decision.1
        if command == .detach {
            // SwiftTUI polls this state to leave TerminalRunner and restore the
            // local terminal. Detach itself performs no blocking host RPC.
            shouldExit = true
        }
        if mode != previousMode || shouldExit != previousShouldExit {
            markPresentationChangedLocked()
        }
        lock.unlock()
        guard let command, command != .detach else { return }
        switch command {
        case .send(let bytes):
            guard let runtime = runtimeForInput() else { return }
            terminalQueue.async { [weak self] in
                guard let self, self.canIssueCommands() else { return }
                self.send(bytes, to: runtime)
            }
        default:
            commandQueue.async { [weak self] in self?.perform(command, now: now) }
        }
    }

    /// Applies a bounded batch from the session's terminal reader. Every
    /// emulator mutation and render snapshot is protected by this model's
    /// lock. Emulator replies are sent only after the lock is released.
    public func apply(_ events: [WorkspaceTUIEvent]) {
        var replies: [(UUID, Data)] = []
        var presentationChanged = false
        lock.lock()
        guard connection == .connected else {
            lock.unlock()
            return
        }
        for event in events {
            switch event {
            case .bytes(let runtime, let data):
                guard terminal?.state.runtime == runtime, let record = terminal else { continue }
                guard data.isEmpty == false else { continue }
                record.emulator.feed(data)
                presentationChanged = true
                let responses = record.emulator.takeResponses()
                if leasedRuntime == runtime, record.state.lease == .owned {
                    replies.append(contentsOf: responses.map { (runtime, $0) })
                }
            case .overflow(let runtime):
                guard terminal?.state.runtime == runtime else { continue }
                if terminal?.state.overflowed != true {
                    terminal?.state.overflowed = true
                    presentationChanged = true
                }
            case .exited(let runtime, let status):
                guard terminal?.state.runtime == runtime else { continue }
                if terminal?.state.running != false || terminal?.state.exitStatus != status
                    || terminal?.state.lease != .released {
                    presentationChanged = true
                }
                terminal?.state.running = false
                terminal?.state.exitStatus = status
                terminal?.state.lease = .released
                if leasedRuntime == runtime { leasedRuntime = nil }
                // The final output stays on screen; the launcher offers a
                // replacement runtime and number keys select it directly.
                if mode != .launcher {
                    mode = .launcher
                    presentationChanged = true
                }
            case .inputOwner(let runtime, let owned):
                guard terminal?.state.runtime == runtime else { continue }
                if owned {
                    // The host broadcasts only that an owner exists, not which
                    // client owns it. Only our successful acquire RPC grants
                    // local write authority.
                    if leasedRuntime != runtime {
                        presentationChanged = presentationChanged || terminal?.state.lease != .readOnly
                        terminal?.state.lease = .readOnly
                    }
                } else {
                    // Notifications do not carry a lease generation. A queued
                    // release from an earlier epoch may arrive after a later
                    // acquire succeeded, so the successful acquire is
                    // authoritative while this client still claims ownership.
                    guard leasedRuntime != runtime else { continue }
                    presentationChanged = presentationChanged || terminal?.state.lease != .readOnly
                    terminal?.state.lease = .readOnly
                    if terminal?.state.running == true {
                        retryAcquire = true
                    }
                }
            }
        }
        if presentationChanged { markPresentationChangedLocked() }
        lock.unlock()

        if replies.isEmpty == false {
            let pendingReplies = replies
            terminalQueue.async { [weak self] in
                guard let self, self.canIssueCommands() else { return }
                for (runtime, bytes) in pendingReplies {
                    self.send(bytes, to: runtime)
                    if self.snapshot().connection == .disconnected { break }
                }
            }
        }
    }

    public func hostDisconnected() {
        markDisconnected()
    }

    /// Records the content area of the terminal. It does not perform an RPC or
    /// resize during SwiftTUI's render pass.
    public func noteSize(rows: Int, columns: Int, now: Date) {
        lock.lock()
        guard terminal != nil, connection == .connected else {
            lock.unlock()
            return
        }
        terminal?.resize.record(rows: rows, columns: columns, now: now)
        viewSize = (rows, columns)
        lock.unlock()
    }

    /// Called by the app's single coalescing timer. Equal dimensions never
    /// produce another RPC; changed dimensions wait for the debounce window.
    public func processPendingWork(now: Date = Date()) {
        var request: (UUID, Int, Int)?
        var shouldAcquire = false
        lock.lock()
        guard connection == .connected else {
            lock.unlock()
            return
        }
        if var record = terminal, let size = record.resize.flush(now: now) {
            record.emulator.resize(columns: size.columns, rows: size.rows)
            request = (record.state.runtime, size.rows, size.columns)
            terminal = record
            markPresentationChangedLocked()
        }
        shouldAcquire = retryAcquire && terminal?.state.lease == .readOnly
        retryAcquire = false
        lock.unlock()

        if let request {
            terminalQueue.async { [weak self] in
                guard let self, self.canIssueCommands() else { return }
                switch self.session.resize(request.0, rows: request.1, columns: request.2) {
                case .success:
                    break
                case .failure(.disconnected):
                    self.markDisconnected()
                case .failure(.unavailable):
                    self.markRuntimeExited(request.0)
                case .failure:
                    break
                }
            }
        }
        if shouldAcquire {
            terminalQueue.async { [weak self] in
                guard let self, self.canIssueCommands() else { return }
                self.reacquireLease()
            }
        }
    }

    public func snapshot() -> WorkspaceTUISnapshot {
        lock.lock()
        defer { lock.unlock() }
        return WorkspaceTUISnapshot(
            project: summary.project,
            phase: summary.phase,
            protected: summary.protected,
            workspace: summary.workspace,
            connection: connection,
            terminal: terminal?.state,
            mode: mode,
            launcher: launcher,
            presentationRevision: presentationRevision,
            shouldExit: shouldExit
        )
    }

    public func terminalFrame() -> TerminalFrame? {
        lock.lock()
        defer { lock.unlock() }
        return terminal?.emulator.frame()
    }

    public func terminalSize() -> (rows: Int, columns: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return terminal?.resize.effectiveSize
    }

    /// Runs during structured application cleanup. It never cancels a runtime
    /// or closes the workspace.
    public func detachSession() {
        let lease: UUID?
        let subscription: UUID?
        lock.lock()
        guard didDetach == false else {
            lock.unlock()
            return
        }
        didDetach = true
        shouldExit = true
        connection = .disconnected
        lease = leasedRuntime
        leasedRuntime = nil
        retryAcquire = false
        subscription = terminal?.state.subscribed == true ? terminal?.state.runtime : nil
        terminal?.state.lease = .released
        terminal?.state.subscribed = false
        markPresentationChangedLocked()
        let pump = self.pump
        self.pump = nil
        lock.unlock()

        pump?.stop()

        // Drain terminal RPCs before closing their dedicated host connection,
        // then drain lifecycle work before closing control.
        terminalQueue.sync {
            if let lease, lease != subscription { session.release(lease) }
            if let subscription { session.release(subscription) }
        }
        commandQueue.sync {
            session.close()
        }
    }

    private func perform(_ command: TUICommand, now: Date) {
        guard canIssueCommands() else { return }
        switch command {
        case .send, .detach, .help, .dismissOverlay:
            break // Routed on the ordered input worker by `handle`, or already applied.
        case .launch(let choice):
            launch(choice)
        }
    }

    private func launch(_ choice: RuntimeLaunchChoice) {
        lock.lock()
        guard connection == .connected, shouldExit == false, didDetach == false,
              terminal?.state.running != true else {
            lock.unlock()
            return
        }
        let oldRuntime = terminal?.state.runtime
        let oldSubscribed = terminal?.state.subscribed == true
        let size = viewSize ?? (initialRows, initialColumns)
        lock.unlock()

        guard case .success(let runtime) = session.launch(
            executable: choice.executable,
            arguments: choice.arguments,
            hook: choice.hook,
            rows: size.rows,
            columns: size.columns
        ) else {
            lock.lock()
            if connection == .connected {
                mode = .launcher
                markPresentationChangedLocked()
            }
            lock.unlock()
            return
        }

        lock.lock()
        let detached = didDetach || shouldExit || connection != .connected
        guard detached == false, terminal?.state.running != true else {
            lock.unlock()
            // A launch that races UI detach belongs to the workspace now. Keep
            // it alive so the next TUI invocation can rediscover it.
            if detached == false { session.cancel(runtime.id) }
            return
        }
        var record = makeRecord(runtime: runtime, rows: size.rows, columns: size.columns)
        record.state.title = choice.title
        terminal = record
        mode = .terminal
        markPresentationChangedLocked()
        lock.unlock()

        if oldSubscribed, let oldRuntime { session.release(oldRuntime) }

        let outcome = session.attach(runtime.id)
        if outcome == .disconnected {
            markDisconnected()
        }
        switch outcome {
        case .owned:
            noteAcquired(runtime.id)
        case .readOnly:
            noteAttached(runtime.id, lease: .readOnly)
        case .unavailable, .disconnected:
            lock.lock()
            if terminal?.state.runtime == runtime.id { terminal = nil }
            if connection == .connected { mode = .launcher }
            markPresentationChangedLocked()
            lock.unlock()
            session.cancel(runtime.id)
        }
    }

    private func runtimeForInput() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard connection == .connected, shouldExit == false, didDetach == false,
              let record = terminal, record.state.running
        else { return nil }
        return record.state.runtime
    }

    private func send(_ bytes: Data, to runtime: UUID) {
        guard bytes.isEmpty == false else { return }
        lock.lock()
        let connected = connection == .connected && shouldExit == false && didDetach == false
        let ownsInput = leasedRuntime == runtime
        let record = terminal
        lock.unlock()
        guard connected, ownsInput, let record, record.state.running,
              record.state.runtime == runtime else { return }
        switch session.send(bytes, to: runtime) {
        case .success:
            break
        case .failure(.busy):
            lock.lock()
            var presentationChanged = false
            if terminal?.state.runtime == runtime {
                presentationChanged = terminal?.state.lease != .readOnly
                terminal?.state.lease = .readOnly
            }
            if leasedRuntime == runtime { leasedRuntime = nil }
            if presentationChanged { markPresentationChangedLocked() }
            lock.unlock()
        case .failure(.disconnected):
            markDisconnected()
        case .failure:
            break
        }
    }

    /// Records a subscribe the session paired with the given lease.
    private func noteAttached(_ runtime: UUID, lease: InputLease) {
        lock.lock()
        if terminal?.state.runtime == runtime {
            if terminal?.state.lease != lease { markPresentationChangedLocked() }
            terminal?.state.subscribed = true
            terminal?.state.lease = lease
        }
        lock.unlock()
    }

    /// Records a subscribe the session paired with a granted input lease. A
    /// lease that arrives after the terminal moved on is released again.
    private func noteAcquired(_ runtime: UUID) {
        lock.lock()
        let stillAvailable = connection == .connected
            && terminal?.state.runtime == runtime && terminal?.state.running == true
        if stillAvailable {
            if terminal?.state.lease != .owned { markPresentationChangedLocked() }
            terminal?.state.subscribed = true
            terminal?.state.lease = .owned
            leasedRuntime = runtime
        }
        lock.unlock()
        if stillAvailable == false { session.release(runtime) }
    }

    /// Records a subscribe the host refused. Nothing was acquired.
    private func noteUnattached(_ runtime: UUID) {
        lock.lock()
        if terminal?.state.runtime == runtime {
            if terminal?.state.lease != .readOnly { markPresentationChangedLocked() }
            terminal?.state.subscribed = false
            terminal?.state.lease = .readOnly
        }
        lock.unlock()
    }

    private func reacquireLease() {
        lock.lock()
        guard connection == .connected, shouldExit == false, didDetach == false,
              let record = terminal, record.state.running else {
            lock.unlock()
            return
        }
        let runtime = record.state.runtime
        lock.unlock()

        switch session.reacquire(runtime) {
        case .owned:
            noteAcquired(runtime)
        case .readOnly, .unavailable:
            noteAttached(runtime, lease: .readOnly)
        case .disconnected:
            markDisconnected()
        }
    }

    private func makeRecord(runtime: ListedRuntime, rows: Int, columns: Int) -> WorkspaceTerminal {
        var resize = ResizeCoalescer()
        resize.recordLaunch(rows: rows, columns: columns)
        return WorkspaceTerminal(
            state: WorkspaceTerminalState(
                runtime: runtime.id,
                title: runtime.hook ?? "runtime",
                running: runtime.running
            ),
            emulator: emulators.make(columns: columns, rows: rows),
            resize: resize
        )
    }

    private func markDisconnected() {
        lock.lock()
        let changed = connection != .disconnected
            || terminal?.state.lease != .readOnly || terminal?.state.subscribed == true
        connection = .disconnected
        leasedRuntime = nil
        retryAcquire = false
        terminal?.state.lease = .readOnly
        terminal?.state.subscribed = false
        if changed { markPresentationChangedLocked() }
        lock.unlock()
    }

    private func markRuntimeExited(_ runtime: UUID) {
        lock.lock()
        guard terminal?.state.runtime == runtime else {
            lock.unlock()
            return
        }
        var changed = terminal?.state.running != false || terminal?.state.exitStatus != nil
            || terminal?.state.lease != .released
        terminal?.state.running = false
        terminal?.state.exitStatus = nil
        terminal?.state.lease = .released
        if leasedRuntime == runtime { leasedRuntime = nil }
        if mode != .launcher {
            mode = .launcher
            changed = true
        }
        if changed { markPresentationChangedLocked() }
        lock.unlock()
    }

    /// Call with `lock` held. SwiftTUI polls this revision to coalesce model
    /// changes instead of invalidating its view tree on every idle timer tick.
    private func markPresentationChangedLocked() {
        presentationRevision &+= 1
    }

    private func canIssueCommands() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection == .connected && shouldExit == false && didDetach == false
    }

    private static func bound(_ value: Int) -> Int {
        min(512, max(1, value))
    }
}

public enum ConnectionState: Equatable, Sendable {
    case connected
    case disconnected
}

public struct WorkspaceTUISnapshot: Equatable, Sendable {
    public var project: String
    public var phase: String
    public var protected: Bool
    public var workspace: UUID
    public var connection: ConnectionState
    public var terminal: WorkspaceTerminalState?
    public var mode: CommandMode
    public var launcher: [RuntimeLaunchChoice]
    public var presentationRevision: UInt64
    public var shouldExit: Bool
}

struct WorkspaceTUIRefreshGate {
    private var revision: UInt64

    init(revision: UInt64) {
        self.revision = revision
    }

    mutating func consume(_ latestRevision: UInt64) -> Bool {
        guard latestRevision != revision else { return false }
        revision = latestRevision
        return true
    }
}
