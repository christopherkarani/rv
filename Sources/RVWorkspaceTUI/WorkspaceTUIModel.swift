import Foundation

/// Presentation state for one workspace shell.
///
/// Process groups, PTYs, capabilities, and recovery stay in the workspace host.
/// This model owns pane-keyed terminal emulators and executes host effects.
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
    private struct EmulatorSlot {
        var binding: PaneBindingKey
        var emulator: any TerminalEmulating
        var revision: UInt64
    }
    /// Created, fed, resized, and read only under `lock`.
    private var emulatorSlots: [PaneID: EmulatorSlot] = [:]
    private var frameRevisionCounter: UInt64 = 0
    /// connect()'s query failure, when the reducer stayed retryable. Written
    /// by `.queryConnect` and read by `connect()`; always under `lock`.
    private var connectError: WorkspaceTUIError?
    /// Fires after a reduce that changed the durable view, outside `lock`.
    /// The save pump uses it to commit without waiting for its poll tick.
    private var onViewChanged: (@Sendable () -> Void)?
    /// Fires with the new view after a reduce that changed bindings or
    /// structure (anything `equalIgnoringFocus` counts), outside `lock`.
    /// The save pump commits synchronously so a crash cannot strand a
    /// binding that already reached the screen.
    private var onDurableViewChanged: (@Sendable (WorkspaceView) -> Void)?

    public init(
        session: any WorkspaceTUISession,
        emulators: any TerminalEmulatorFactory = SwiftTermFactory(),
        summary: WorkspaceTUISummary,
        launcher: [RuntimeLaunchChoice],
        defaultShellID: String = "shell",
        rows: Int = 24,
        columns: Int = 80,
        restoredView: WorkspaceView? = nil,
        initialViewID: ViewID? = nil
    ) {
        self.session = session
        self.emulators = emulators
        let acceptedView = restoredView.flatMap { view -> WorkspaceView? in
            guard view.validate().isEmpty,
                  view.panes.values.allSatisfy({ $0.binding?.workspace.rawValue == summary.workspace || $0.binding == nil })
            else { return nil }
            return view
        }
        self.state = WorkspaceTUIState(
            lifecycle: .neverConnected,
            summary: summary,
            launcher: launcher,
            defaultShellID: defaultShellID,
            initialRows: Self.bound(rows),
            initialColumns: Self.bound(columns),
            mode: .terminal,
            terminal: nil,
            leasedRuntime: nil,
            retryAcquire: false,
            shouldExit: false,
            initialLaunchRequested: false,
            viewSize: nil,
            presentationRevision: 0,
            viewID: initialViewID ?? ViewID(),
            restoredView: acceptedView
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

    /// Starts the session's event reader. Restart-safe: a dead pump from a
    /// previous disconnect is stopped and replaced, so reconnect can resume
    /// delivery on the reopened connections. The reader stops inside
    /// `detachSession`. The app calls this once after `connect` succeeds.
    public func startEventDelivery() {
        lock.lock()
        let old = pump
        pump = nil
        lock.unlock()
        old?.stop()
        let fresh = SessionEventPump()
        lock.lock()
        pump = fresh
        lock.unlock()
        fresh.start(
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
            case .queueSend, .queueKey, .queuePaste, .queueEmulatorResponse, .releaseInput: .terminal
            case .queueLaunch, .refreshInventory: .command
            default: .inline
            }
        })
    }

    /// Applies a bounded batch from the session's terminal reader. Every
    /// emulator mutation and render snapshot is protected by this model's
    /// lock. Emulator replies are sent only after the lock is released.
    public func apply(_ events: [WorkspaceTUIEvent]) {
        drain(.hostEvents(events), route: {
            switch $0 {
            case .queueSend, .queueEmulatorResponse: .terminal
            default: .inline
            }
        })
    }

    public func handlePaste(_ content: String) {
        drain(.paste(content), route: {
            if case .queuePaste = $0 { .terminal } else { .inline }
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

    public func noteSize(for paneID: PaneID, rows: Int, columns: Int, now: Date = Date()) {
        drain(.paneSizeNoted(pane: paneID, rows: rows, columns: columns, now: now), route: { _ in .inline })
    }

    public func noteViewport(rows: Int, columns: Int) {
        drain(.viewportNoted(rows: rows, columns: columns), route: { _ in .inline })
    }

    /// Called by the app's single coalescing timer. Equal dimensions never
    /// produce another RPC; changed dimensions wait for the debounce window.
    public func processPendingWork(now: Date = Date()) {
        drain(.tick(now: now), route: {
            switch $0 {
            case .resize, .acquire: .terminal
            case .reconnectQuery: .command
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
            shouldExit: state.shouldExit,
            feedback: state.feedback,
            view: state.view,
            terminals: state.terminals.mapValues(\.state),
            recentOutputOnly: state.recentOutputOnly,
            scrollAnchors: state.scrollAnchors,
            navigatorItems: state.navigatorItems,
            knownRuntimes: state.knownRuntimes,
            reconnecting: state.lifecycle == .disconnected
                && (state.reconnectInflight || state.reconnectFiresAt != nil
                    || state.reconnectAttempt < WorkspaceTUIReducer.maxReconnectAttempts),
            frameRevisions: emulatorSlots.mapValues(\.revision)
        )
    }

    public func snapshotView() -> WorkspaceView {
        lock.lock()
        defer { lock.unlock() }
        return state.view
    }

    /// Registers the hook `reduceAndApply` fires after a view-changing
    /// reduce. Called outside the model lock; must never reduce re-entrantly.
    public func setViewChangedHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        onViewChanged = hook
        lock.unlock()
    }

    /// Registers the hook `reduceAndApply` fires with the new view after
    /// a durable (bindings/structure) change. Runs on the reducing thread
    /// outside the model lock; keep it to the synchronous save, which is
    /// rare (launches, splits, closes) and never on the typing path.
    public func setDurableViewChangedHook(_ hook: (@Sendable (WorkspaceView) -> Void)?) {
        lock.lock()
        onDurableViewChanged = hook
        lock.unlock()
    }

    public func reportNotice(_ message: String) {
        drain(.notice(message), route: { _ in .inline })
    }

    public func terminalFrame() -> TerminalFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let binding = state.activeBindingKey,
              let slot = emulatorSlots[binding.pane], slot.binding == binding else { return nil }
        return slot.emulator.frame()
    }

    public func terminalFrame(for paneID: PaneID) -> TerminalFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let tab = state.view.activeTab,
              (tab.zoomedPaneID.map { $0 == paneID } ?? tab.tree.leafIDs.contains(paneID)) else { return nil }
        guard let binding = state.bindingKey(for: paneID),
              let slot = emulatorSlots[paneID], slot.binding == binding else { return nil }
        return slot.emulator.frame()
    }

    /// Scrollback viewport for scroll mode. Returns nil at anchor 0, on the
    /// alternate screen, or without a bound emulator, so the caller renders
    /// the live frame instead.
    public func scrollFrame(for paneID: PaneID, rows: Int) -> TerminalFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let tab = state.view.activeTab,
              (tab.zoomedPaneID.map { $0 == paneID } ?? tab.tree.leafIDs.contains(paneID)) else { return nil }
        guard let binding = state.bindingKey(for: paneID),
              let slot = emulatorSlots[paneID], slot.binding == binding else { return nil }
        let anchor = state.scrollAnchors[paneID] ?? 0
        guard anchor > 0 else { return nil }
        return slot.emulator.historyFrame(anchor: anchor, rows: rows, columns: slot.emulator.columns)
    }

    public func terminalSize(for paneID: PaneID) -> (rows: Int, columns: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return state.terminals[paneID]?.resize.effectiveSize
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
                        guard let self, self.commandsAllowed(for: effect) else { return }
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
        case .queuePaste(let binding, let text):
            lock.lock()
            let modes = emulatorSlots[binding.pane].flatMap { $0.binding == binding ? $0.emulator.inputModes : nil }
                ?? TerminalInputModes()
            lock.unlock()
            drain(.sendDue(binding: binding, bytes: TerminalInputEncoding.paste(text, modes: modes)),
                  route: { _ in .inline })
        case .queueEmulatorResponse(let binding, let bytes):
            drain(.emulatorSendDue(binding: binding, bytes: bytes), route: { _ in .inline })
        case .queueKey(let binding, let key):
            lock.lock()
            let modes = emulatorSlots[binding.pane].flatMap { $0.binding == binding ? $0.emulator.inputModes : nil }
                ?? TerminalInputModes()
            lock.unlock()
            drain(.sendDue(binding: binding, bytes: TerminalInputEncoding.bytes(for: key, modes: modes)),
                  route: { _ in .inline })
        case .queueSend(let binding, let bytes):
            drain(.sendDue(binding: binding, bytes: bytes), route: { _ in .inline })
        case .queueLaunch(let target, let choice):
            drain(.launchDue(target: target, choice: choice), route: { _ in .inline })
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
            case .createEmulator(let binding, let rows, let columns):
                frameRevisionCounter &+= 1
                emulatorSlots[binding.pane] = EmulatorSlot(
                    binding: binding, emulator: emulators.make(columns: columns, rows: rows),
                    revision: frameRevisionCounter
                )
            case .feedEmulator(let binding, let data):
                if let slot = emulatorSlots[binding.pane], slot.binding == binding {
                    slot.emulator.feed(data)
                    frameRevisionCounter &+= 1
                    emulatorSlots[binding.pane]?.revision = frameRevisionCounter
                    let responses = slot.emulator.takeResponses()
                    if responses.isEmpty == false {
                        followups.append(.emulatorResponded(binding: binding, responses: responses))
                    }
                }
            case .resizeEmulator(let binding, let rows, let columns):
                if let slot = emulatorSlots[binding.pane], slot.binding == binding {
                    slot.emulator.resize(columns: columns, rows: rows)
                    frameRevisionCounter &+= 1
                    emulatorSlots[binding.pane]?.revision = frameRevisionCounter
                }
            case .dropEmulator(let binding):
                if emulatorSlots[binding.pane]?.binding == binding {
                    emulatorSlots[binding.pane] = nil
                }
            default:
                remaining.append(effect)
            }
        }
        let viewChanged = transition.state.view != state.view
        let hook = viewChanged ? onViewChanged : nil
        let durableHook = viewChanged
            && transition.state.view.equalIgnoringFocus(state.view) == false ? onDurableViewChanged : nil
        let durableView = transition.state.view
        state = transition.state
        lock.unlock()
        hook?()
        if let durableHook { durableHook(durableView) }
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

        case .ensureShell(let target, let choice, let rows, let columns):
            switch session.ensureTerminal(
                executable: choice.executable,
                arguments: choice.arguments,
                hook: choice.hook,
                rows: rows,
                columns: columns,
                resourceProfileID: choice.resourceProfileID
            ) {
            case .success(let runtime):
                followups.append(.ensureSucceeded(target: target, runtime: runtime, shell: choice))
            case .failure(let error):
                followups.append(.ensureFailed(
                    target: target, error: error, profileID: choice.resourceProfileID
                ))
            }

        case .queueSend(let binding, let bytes):
            // Inline fallback; queue-routed callers reduce `.sendDue` on the
            // terminal worker instead.
            followups.append(.sendDue(binding: binding, bytes: bytes))

        case .queueEmulatorResponse(let binding, let bytes):
            followups.append(.emulatorSendDue(binding: binding, bytes: bytes))

        case .queueKey(let binding, let key):
            lock.lock()
            let modes = emulatorSlots[binding.pane].flatMap { $0.binding == binding ? $0.emulator.inputModes : nil }
                ?? TerminalInputModes()
            lock.unlock()
            followups.append(.sendDue(
                binding: binding, bytes: TerminalInputEncoding.bytes(for: key, modes: modes)
            ))

        case .queuePaste(let binding, let text):
            lock.lock()
            let modes = emulatorSlots[binding.pane].flatMap { $0.binding == binding ? $0.emulator.inputModes : nil }
                ?? TerminalInputModes()
            lock.unlock()
            followups.append(.sendDue(
                binding: binding, bytes: TerminalInputEncoding.paste(text, modes: modes)
            ))

        case .resolveRunCommand(let target, let input):
            guard let selection = RunCommandSelection.splitProfile(input) else {
                followups.append(.runCommandFailed(target: target, message: "Invalid resource profile"))
                return
            }
            let parsed: ParsedRuntimeCommand
            switch RunCommandParser.parse(selection.command) {
            case .success(let value): parsed = value
            case .failure(let error):
                followups.append(.runCommandFailed(target: target, message: error.message))
                return
            }
            switch RunCommandParser.resolve(
                parsed, path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ) {
            case .success(let resolved):
                followups.append(.runCommandResolved(target: target, choice: RuntimeLaunchChoice(
                    id: "run", title: URL(fileURLWithPath: resolved.executable).lastPathComponent,
                    executable: resolved.executable, arguments: resolved.arguments,
                    hook: nil, resourceProfileID: selection.profileID
                )))
            case .failure(let error):
                followups.append(.runCommandFailed(target: target, message: error.message))
            }

        case .queueLaunch(let target, let choice):
            // Inline fallback; queue-routed callers reduce `.launchDue` on the
            // command worker instead.
            followups.append(.launchDue(target: target, choice: choice))

        case .launchQuery(let target, let choice, let rows, let columns):
            switch session.launch(
                executable: choice.executable,
                arguments: choice.arguments,
                hook: choice.hook,
                rows: rows,
                columns: columns,
                resourceProfileID: choice.resourceProfileID
            ) {
            case .success(let runtime):
                followups.append(.launchQuerySucceeded(
                    target: target, choice: choice, runtime: runtime, rows: rows, columns: columns
                ))
            case .failure(let error):
                followups.append(.launchQueryFailed(target: target, choice: choice, error: error))
            }

        case .attach(let binding, let context):
            // Resubscribe recovery tears down stale subscription state and
            // clears the client's queued backlog; a bare attach would leave
            // the swallow-output mark set and the pane dark.
            let outcome: SessionAttachOutcome
            if context == .resubscribe || context == .resubscribeRetry {
                outcome = session.resubscribe(binding.runtime)
            } else {
                outcome = session.attach(binding.runtime)
            }
            followups.append(.attachCompleted(
                binding: binding, context: context, outcome: outcome
            ))

        case .observe(let binding, let context):
            lock.lock()
            let observe = state.bindingKey(for: binding.pane) == binding
                && state.terminals[binding.pane]?.state.running == true
            lock.unlock()
            guard observe else { return }
            followups.append(.attachCompleted(
                binding: binding, context: context, outcome: session.observe(binding.runtime)
            ))

        case .reconnectQuery:
            switch session.reconnect() {
            case .failure(let error):
                followups.append(.reconnectFailed(error: error))
            case .success:
                switch session.inventory() {
                case .success(let inventoried):
                    followups.append(.reconnectSucceeded(terminals: inventoried.terminals))
                case .failure(let error):
                    followups.append(.reconnectFailed(error: error))
                }
            }

        case .restartEvents:
            startEventDelivery()

        case .release(let runtime):
            session.release(runtime)
        case .releaseInput(let binding):
            lock.lock()
            let attempt = state.lifecycle == .connected && state.shouldExit == false
                && state.bindingKey(for: binding.pane) == binding
            lock.unlock()
            guard attempt else { return }
            followups.append(.releaseInputCompleted(
                binding: binding, outcome: .from(session.releaseInput(binding.runtime))
            ))
        case .refreshInventory:
            switch session.inventory() {
            case .success(let inventoried):
                followups.append(.inventoryRefreshed(terminals: inventoried.terminals))
            case .failure(.disconnected):
                followups.append(.hostDisconnected)
            case .failure:
                break
            }
        case .cancel(let runtime):
            session.cancel(runtime)
        case .detach:
            session.close()

        case .acquire(let binding):
            // Narrow the race between the reducer's gate and the RPC: a
            // detach that lands in between skips the call. A success that
            // still arrives stale is released by `.acquireCompleted`.
            lock.lock()
            let attempt = state.lifecycle == .connected && state.shouldExit == false
                && state.bindingKey(for: binding.pane) == binding
                && state.terminals[binding.pane]?.state.running == true
            lock.unlock()
            guard attempt else { return }
            let outcome: TUIRPCOutcome
            switch session.reacquire(binding.runtime) {
            case .owned:
                outcome = .ok
            case .readOnly:
                outcome = .busy
            case .unavailable:
                outcome = .unavailable
            case .disconnected:
                outcome = .disconnected
            }
            followups.append(.acquireCompleted(binding: binding, outcome: outcome))

        case .write(let binding, let bytes):
            guard bytes.isEmpty == false else { return }
            followups.append(.writeCompleted(
                binding: binding, bytes: bytes, outcome: .from(session.send(bytes, to: binding.runtime))
            ))

        case .resize(let binding, let rows, let columns):
            followups.append(.resizeCompleted(
                binding: binding,
                rows: rows,
                columns: columns,
                outcome: .from(session.resize(binding.runtime, rows: rows, columns: columns)),
                now: Date()
            ))

        case .createEmulator(let binding, let rows, let columns):
            lock.lock()
            frameRevisionCounter &+= 1
            emulatorSlots[binding.pane] = EmulatorSlot(
                binding: binding, emulator: emulators.make(columns: columns, rows: rows),
                revision: frameRevisionCounter
            )
            lock.unlock()

        case .feedEmulator(let binding, let data):
            lock.lock()
            var responses: [Data] = []
            if let slot = emulatorSlots[binding.pane], slot.binding == binding {
                slot.emulator.feed(data)
                frameRevisionCounter &+= 1
                emulatorSlots[binding.pane]?.revision = frameRevisionCounter
                responses = slot.emulator.takeResponses()
            }
            lock.unlock()
            if responses.isEmpty == false {
                followups.append(.emulatorResponded(binding: binding, responses: responses))
            }

        case .resizeEmulator(let binding, let rows, let columns):
            lock.lock()
            if let slot = emulatorSlots[binding.pane], slot.binding == binding {
                slot.emulator.resize(columns: columns, rows: rows)
                frameRevisionCounter &+= 1
                emulatorSlots[binding.pane]?.revision = frameRevisionCounter
            }
            lock.unlock()

        case .dropEmulator(let binding):
            lock.lock()
            if emulatorSlots[binding.pane]?.binding == binding {
                emulatorSlots[binding.pane] = nil
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

    private func commandsAllowed(for effect: TUIRuntimeEffect) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Reconnect is the one command-queue effect that must run while
        // disconnected; everything else stays gated on a live session.
        if case .reconnectQuery = effect {
            return state.lifecycle == .disconnected && state.shouldExit == false
        }
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
    public var feedback: String?
    public var view: WorkspaceView
    public var terminals: [PaneID: WorkspaceTerminalState]
    public var recentOutputOnly: Set<PaneID>
    public var scrollAnchors: [PaneID: Int]
    public var navigatorItems: [NavigatorItem]
    public var knownRuntimes: [ListedRuntime]
    public var reconnecting: Bool
    public var frameRevisions: [PaneID: UInt64]
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
