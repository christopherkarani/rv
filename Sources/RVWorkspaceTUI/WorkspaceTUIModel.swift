import Foundation

/// Presentation state for one workspace shell.
///
/// Process groups, PTYs, capabilities, and recovery stay in the workspace host.
/// This model owns the one visible terminal, its render state, and
/// command-prefix mode. Panes and tabs are deferred: at most one runtime is
/// attached, and a later attach reuses the existing runtime inventory.
///
/// All decisions live in the pure `WorkspaceTUIReducer`. This class is the
/// thin runtime: it owns the session, the emulator object, the lock, and the
/// queues, and executes the effects the reducer returns.
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
    private var state: WorkspaceTUIState
    private var pump: SessionEventPump?
    /// The emulator for the attached terminal. Created, fed, resized, and read
    /// only while `lock` is held; renderers use `terminalFrame()` snapshots.
    private var emulator: (runtime: UUID, emulator: any TerminalEmulating)?
    /// connect()'s query failure, when the reducer stayed retryable. Written
    /// by `.queryConnect` and read by `connect()`; always under `lock`.
    private var connectError: WorkspaceTUIError?

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
        self.state = WorkspaceTUIState(
            lifecycle: .neverConnected,
            summary: summary,
            launcher: launcher,
            initialRows: Self.bound(rows),
            initialColumns: Self.bound(columns),
            mode: .terminal,
            terminal: nil,
            leasedRuntime: nil,
            retryAcquire: false,
            shouldExit: false,
            initialLaunchRequested: false,
            viewSize: nil,
            presentationRevision: 0
        )
    }

    /// Inventories through the session and attaches to the first terminal
    /// runtime. Repeated calls are harmless and never create another runtime.
    /// A disconnected attach fails: callers must not start event delivery
    /// against a dead connection.
    public func connect() -> Result<Void, WorkspaceTUIError> {
        lock.lock()
        let lifecycle = state.lifecycle
        lock.unlock()
        guard lifecycle == .neverConnected else {
            return lifecycle == .connected ? .success(()) : .failure(.disconnected)
        }
        lock.lock()
        connectError = nil
        lock.unlock()
        drain(.connectRequested, route: { _ in .inline })
        // A failed first query stays retryable and reports the underlying
        // inventory error, as the previous model did.
        guard connectedNow() else {
            lock.lock()
            defer { lock.unlock() }
            return .failure(connectError ?? .disconnected)
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
        drain(.launchDefaultRequested, route: { _ in .inline })
    }

    public func handle(_ key: TUIKey, now: Date = Date()) {
        _ = now
        drain(.key(key), route: {
            switch $0 {
            case .queueSend: .terminal
            case .queueLaunch: .command
            default: .inline
            }
        })
    }

    /// Applies a bounded batch from the session's terminal reader. Every
    /// emulator mutation and render snapshot is protected by this model's
    /// lock. Emulator replies are sent only after the lock is released.
    public func apply(_ events: [WorkspaceTUIEvent]) {
        drain(.hostEvents(events), route: {
            if case .queueSend = $0 { .terminal } else { .inline }
        })
    }

    public func hostDisconnected() {
        drain(.hostDisconnected, route: { _ in .inline })
    }

    /// Records the content area of the terminal. It does not perform an RPC or
    /// resize during SwiftTUI's render pass.
    public func noteSize(rows: Int, columns: Int, now: Date) {
        drain(.sizeNoted(rows: rows, columns: columns, now: now), route: { _ in .inline })
    }

    /// Called by the app's single coalescing timer. Equal dimensions never
    /// produce another RPC; changed dimensions wait for the debounce window.
    public func processPendingWork(now: Date = Date()) {
        drain(.tick(now: now), route: {
            switch $0 {
            case .resize, .acquire: .terminal
            default: .inline
            }
        })
    }

    public func snapshot() -> WorkspaceTUISnapshot {
        lock.lock()
        defer { lock.unlock() }
        return WorkspaceTUISnapshot(
            project: state.summary.project,
            phase: state.summary.phase,
            protected: state.summary.protected,
            workspace: state.summary.workspace,
            connection: state.lifecycle == .connected ? .connected : .disconnected,
            terminal: state.terminal?.state,
            mode: state.mode,
            launcher: state.launcher,
            presentationRevision: state.presentationRevision,
            shouldExit: state.shouldExit
        )
    }

    public func terminalFrame() -> TerminalFrame? {
        lock.lock()
        defer { lock.unlock() }
        return emulator?.emulator.frame()
    }

    public func terminalSize() -> (rows: Int, columns: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return state.terminal?.resize.effectiveSize
    }

    /// Runs during structured application cleanup. It never cancels a runtime
    /// or closes the workspace.
    public func detachSession() {
        lock.lock()
        let pump = self.pump
        self.pump = nil
        lock.unlock()
        pump?.stop()
        let effects = reduceAndApply(.detachRequested).effects
        // A repeat call is a no-op: the reducer emits no `.detach` effect once
        // detached, and the previous model early-returned without any RPC.
        guard effects.contains(.detach) else { return }
        var releases: [UUID] = []
        for effect in effects {
            if case .release(let runtime) = effect {
                releases.append(runtime)
            }
        }
        // Drain terminal RPCs before closing their dedicated host connection,
        // then drain lifecycle work before closing control.
        terminalQueue.sync {
            for release in releases { session.release(release) }
        }
        commandQueue.sync {
            session.close()
        }
    }

    // MARK: - Runtime effect boundary

    /// Where one effect executes. Queue choice is the runtime's discipline;
    /// the reducer never dispatches.
    private enum QueueHop {
        case inline
        case terminal
        case command
    }

    /// Reduces one event under the lock and executes its effects. Inline
    /// effects run in the current context; routed effects hop to their queue,
    /// where the worker re-checks `commandsAllowed()` before executing. This
    /// preserves the previous per-method dispatch: key sends and emulator
    /// replies ride the terminal queue, launches ride the command queue, and
    /// synchronous queries (connect, ensure) run on the caller.
    private func drain(_ event: WorkspaceTUIReducerEvent, route: (TUIRuntimeEffect) -> QueueHop) {
        var events = [event]
        while let current = events.first {
            events.removeFirst()
            let applied = reduceAndApply(current)
            events.append(contentsOf: applied.followups)
            for effect in applied.effects {
                switch route(effect) {
                case .inline:
                    runInline(effect, followups: &events)
                case .terminal:
                    terminalQueue.async { [weak self] in
                        guard let self, self.commandsAllowed() else { return }
                        self.runRouted(effect)
                    }
                case .command:
                    commandQueue.async { [weak self] in
                        guard let self, self.commandsAllowed() else { return }
                        self.runRouted(effect)
                    }
                }
            }
        }
    }

    /// Executes one queue-routed effect on its worker. Routed sends and
    /// launches re-gate through their Due event first, so a detach or lease
    /// move that landed while the work was queued still wins.
    private func runRouted(_ effect: TUIRuntimeEffect) {
        switch effect {
        case .queueSend(let runtime, let bytes):
            drain(.sendDue(runtime: runtime, bytes: bytes), route: { _ in .inline })
        case .queueLaunch(let choice):
            drain(.launchDue(choice: choice), route: { _ in .inline })
        default:
            var followups: [WorkspaceTUIReducerEvent] = []
            runInline(effect, followups: &followups)
            for followup in followups {
                drain(followup, route: { _ in .inline })
            }
        }
    }

    /// Reduces one event and stores the next state. Called with no lock held.
    ///
    /// Emulator effects commit under the same hold as the state: the
    /// presentation revision and the emulator move together, so a renderer
    /// that snapshots the new revision can never read the stale frame. Feed
    /// replies are captured under the hold and returned as follow-ups; the
    /// drain loop reduces them after the lock is released.
    private func reduceAndApply(_ event: WorkspaceTUIReducerEvent) -> (
        effects: [TUIRuntimeEffect], followups: [WorkspaceTUIReducerEvent]
    ) {
        lock.lock()
        let transition = WorkspaceTUIReducer.reduce(state, event)
        var followups: [WorkspaceTUIReducerEvent] = []
        var remaining: [TUIRuntimeEffect] = []
        remaining.reserveCapacity(transition.effects.count)
        for effect in transition.effects {
            switch effect {
            case .createEmulator(let runtime, let rows, let columns):
                emulator = (runtime, emulators.make(columns: columns, rows: rows))
            case .feedEmulator(let runtime, let data):
                if emulator?.runtime == runtime {
                    emulator?.emulator.feed(data)
                    let responses = emulator?.emulator.takeResponses() ?? []
                    if responses.isEmpty == false {
                        followups.append(.emulatorResponded(runtime: runtime, responses: responses))
                    }
                }
            case .resizeEmulator(let runtime, let rows, let columns):
                if emulator?.runtime == runtime {
                    emulator?.emulator.resize(columns: columns, rows: rows)
                }
            case .dropEmulator(let runtime):
                if emulator?.runtime == runtime {
                    emulator = nil
                }
            default:
                remaining.append(effect)
            }
        }
        state = transition.state
        lock.unlock()
        return (remaining, followups)
    }

    /// Executes one effect in the current context. RPCs run outside the lock.
    /// Emulator effects commit under the reduce hold in `reduceAndApply`, so
    /// the emulator cases below only serve direct callers. Completions are
    /// appended as follow-up events for the drain loop to reduce.
    private func runInline(_ effect: TUIRuntimeEffect, followups: inout [WorkspaceTUIReducerEvent]) {
        switch effect {
        case .queryConnect:
            switch session.inventory() {
            case .success(let inventoried):
                followups.append(.connectQuery(described: inventoried.summary, runtimes: inventoried.terminals))
            case .failure(let error):
                setConnectError(error)
                followups.append(.connectQueryFailed)
            }

        case .ensureShell(let choice, let rows, let columns):
            switch session.ensureTerminal(
                executable: choice.executable,
                arguments: choice.arguments,
                hook: choice.hook,
                rows: rows,
                columns: columns
            ) {
            case .success(let runtime):
                followups.append(.ensureSucceeded(runtime: runtime, shell: choice))
            case .failure(let error):
                followups.append(.ensureFailed(disconnected: error == .disconnected))
            }

        case .queueSend(let runtime, let bytes):
            // Inline fallback; queue-routed callers reduce `.sendDue` on the
            // terminal worker instead.
            followups.append(.sendDue(runtime: runtime, bytes: bytes))

        case .queueLaunch(let choice):
            // Inline fallback; queue-routed callers reduce `.launchDue` on the
            // command worker instead.
            followups.append(.launchDue(choice: choice))

        case .launchQuery(let choice, let rows, let columns):
            switch session.launch(
                executable: choice.executable,
                arguments: choice.arguments,
                hook: choice.hook,
                rows: rows,
                columns: columns
            ) {
            case .success(let runtime):
                followups.append(.launchQuerySucceeded(choice: choice, runtime: runtime, rows: rows, columns: columns))
            case .failure:
                followups.append(.launchQueryFailed)
            }

        case .attach(let runtime, let context):
            followups.append(.attachCompleted(runtime: runtime, context: context, outcome: session.attach(runtime)))

        case .release(let runtime):
            session.release(runtime)
        case .cancel(let runtime):
            session.cancel(runtime)
        case .detach:
            session.close()

        case .acquire(let runtime):
            // Narrow the race between the reducer's gate and the RPC: a
            // detach that lands in between skips the call. A success that
            // still arrives stale is released by `.acquireCompleted`.
            lock.lock()
            let attempt = state.lifecycle == .connected && state.shouldExit == false
                && state.terminal?.state.runtime == runtime
                && state.terminal?.state.running == true
            lock.unlock()
            guard attempt else { return }
            let outcome: TUIRPCOutcome
            switch session.reacquire(runtime) {
            case .owned:
                outcome = .ok
            case .readOnly, .unavailable:
                outcome = .busy
            case .disconnected:
                outcome = .disconnected
            }
            followups.append(.acquireCompleted(runtime: runtime, outcome: outcome))

        case .write(let runtime, let bytes):
            guard bytes.isEmpty == false else { return }
            followups.append(.writeCompleted(runtime: runtime, outcome: .from(session.send(bytes, to: runtime))))

        case .resize(let runtime, let rows, let columns):
            followups.append(.resizeCompleted(runtime: runtime, outcome: .from(session.resize(runtime, rows: rows, columns: columns))))

        case .createEmulator(let runtime, let rows, let columns):
            lock.lock()
            emulator = (runtime, emulators.make(columns: columns, rows: rows))
            lock.unlock()

        case .feedEmulator(let runtime, let data):
            lock.lock()
            var responses: [Data] = []
            if emulator?.runtime == runtime {
                emulator?.emulator.feed(data)
                responses = emulator?.emulator.takeResponses() ?? []
            }
            lock.unlock()
            if responses.isEmpty == false {
                followups.append(.emulatorResponded(runtime: runtime, responses: responses))
            }

        case .resizeEmulator(let runtime, let rows, let columns):
            lock.lock()
            if emulator?.runtime == runtime {
                emulator?.emulator.resize(columns: columns, rows: rows)
            }
            lock.unlock()

        case .dropEmulator(let runtime):
            lock.lock()
            if emulator?.runtime == runtime {
                emulator = nil
            }
            lock.unlock()
        }
    }

    private func connectedNow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.lifecycle == .connected
    }

    private func commandsAllowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.lifecycle == .connected && state.shouldExit == false
    }

    private func setConnectError(_ error: WorkspaceTUIError) {
        lock.lock()
        connectError = error
        lock.unlock()
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
