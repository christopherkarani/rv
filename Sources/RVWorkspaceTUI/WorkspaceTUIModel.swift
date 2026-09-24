import Foundation

/// Presentation state for one workspace shell.
///
/// Process groups, PTYs, capabilities, and recovery stay in the workspace host.
/// This model owns the pane tree, terminal render state, and command-prefix
/// mode. Layout is not persisted: a later attach builds a new balanced tree
/// from the live runtime inventory.
public final class WorkspaceTUIModel: @unchecked Sendable {
    private let client: any WorkspaceTUIClient
    private let emulators: any TerminalEmulatorFactory
    private let lock = NSLock()
    /// Lifecycle RPCs use a separate Workspace Host connection. Cancellation
    /// can wait for child teardown without blocking terminal I/O.
    private let commandQueue = DispatchQueue(label: "rv.workspace-tui.commands")
    /// Lease, write, and resize RPCs share the adapter's independent terminal
    /// connection and stay ordered with each other.
    private let terminalQueue = DispatchQueue(label: "rv.workspace-tui.terminal")
    private var tree: PaneTree = .empty
    private var focusedPane: PaneID?
    private var focusRevision: UInt64 = 0
    private var presentationRevision: UInt64 = 0
    private var panes: [PaneID: TerminalPaneModel] = [:]
    private var mode: CommandMode = .terminal
    private var connection: ConnectionState = .disconnected
    private var summary: WorkspaceTUISummary
    private let launcher: [RuntimeLaunchChoice]
    private var shouldExit = false
    private var didConnect = false
    private var didDetach = false
    private var initialRuntimeLaunchRequested = false
    private var leasedRuntime: UUID?
    private var pendingInputAcquisitions = Set<PaneID>()
    private var canvas = PaneRect(x: 0, y: 0, width: 80, height: 24)
    private let initialRows: Int
    private let initialColumns: Int

    public init(
        client: any WorkspaceTUIClient,
        emulators: any TerminalEmulatorFactory = SwiftTermFactory(),
        summary: WorkspaceTUISummary,
        launcher: [RuntimeLaunchChoice],
        rows: Int = 24,
        columns: Int = 80
    ) {
        self.client = client
        self.emulators = emulators
        self.summary = summary
        self.launcher = launcher
        self.initialRows = Self.bound(rows)
        self.initialColumns = Self.bound(columns)
    }

    /// Describes and inventories through WorkspaceHostClient's public surface.
    /// Repeated calls are harmless and never create another runtime or pane.
    public func connect() -> Result<Void, WorkspaceTUIClientError> {
        lock.lock()
        if didConnect {
            let connected = connection == .connected
            lock.unlock()
            return connected ? .success(()) : .failure(.disconnected)
        }
        lock.unlock()

        let described: WorkspaceTUISummary
        switch client.describe() {
        case .success(let value): described = value
        case .failure(let error):
            markDisconnected()
            return .failure(error)
        }
        let runtimes: [ListedRuntime]
        switch client.listRuntimes() {
        case .success(let values):
            runtimes = values
                .filter(\.terminal)
                .sorted { $0.id.uuidString < $1.id.uuidString }
        case .failure(let error):
            markDisconnected()
            return .failure(error)
        }

        lock.lock()
        summary = described
        connection = .connected
        didConnect = true
        let ids = runtimes.map { _ in PaneID() }
        let treeResult = PaneTree.balanced(ids)
        guard case .success(let inventoryTree) = treeResult else {
            connection = .disconnected
            lock.unlock()
            return .failure(.rejected)
        }
        tree = inventoryTree
        focusedPane = inventoryTree.firstLeaf
        for (pane, runtime) in zip(ids, runtimes) {
            let rows = runtime.rows.map(Self.bound) ?? initialRows
            let columns = runtime.columns.map(Self.bound) ?? initialColumns
            panes[pane] = makeRecord(pane: pane, runtime: runtime, rows: rows, columns: columns)
        }
        markPresentationChangedLocked()
        let focus = focusedPane
        lock.unlock()

        for (pane, runtime) in zip(ids, runtimes) {
            if case .failure(.disconnected) = bind(pane, runtime: runtime.id) {
                markDisconnected()
                return .failure(.disconnected)
            }
        }
        if let focus { acquire(focus) }
        return .success(())
    }

    /// Establishes a host-owned terminal before the local terminal begins
    /// accepting input. The host serializes this operation across TUI clients.
    public func launchDefaultRuntimeIfEmpty() {
        lock.lock()
        guard didConnect, connection == .connected, didDetach == false, shouldExit == false,
              tree.isEmpty, initialRuntimeLaunchRequested == false else {
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
        switch client.ensureTerminalRuntime(
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
            if tree.isEmpty, connection == .connected {
                mode = .launcher
                markPresentationChangedLocked()
            }
            lock.unlock()
            return
        }

        let pane = PaneID()
        let rows = runtime.rows.map(Self.bound) ?? initialRows
        let columns = runtime.columns.map(Self.bound) ?? initialColumns
        let title: String
        if let hook = runtime.hook {
            title = launcher.first(where: { $0.hook == hook })?.title ?? hook
        } else {
            title = runtime.created ? shell.title : "runtime"
        }
        lock.lock()
        guard tree.isEmpty, connection == .connected, didDetach == false, shouldExit == false else {
            lock.unlock()
            return
        }
        tree = .leaf(pane)
        focusedPane = pane
        focusRevision &+= 1
        var record = makeRecord(pane: pane, runtime: runtime, rows: rows, columns: columns)
        record.state.title = title
        panes[pane] = record
        markPresentationChangedLocked()
        lock.unlock()

        if case .success = bind(pane, runtime: runtime.id) {
            acquire(pane)
        } else {
            lock.lock()
            if let record = panes[pane], record.state.subscribed == false {
                panes[pane]?.state.title = "\(title) (unavailable)"
                panes[pane]?.state.lease = .readOnly
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
            directLauncherSelection: tree.isEmpty
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
        case .focus(let direction):
            moveFocus(direction)
        case .send(let bytes):
            guard let runtime = focusedRuntimeForInput() else { return }
            terminalQueue.async { [weak self] in
                guard let self, self.canIssueCommands() else { return }
                self.send(bytes, to: runtime)
            }
        default:
            commandQueue.async { [weak self] in self?.perform(command, now: now) }
        }
    }

    /// Applies a bounded batch from the one WorkspaceClient terminal reader.
    /// Every emulator mutation and render snapshot is protected by this model's
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
                guard let pane = pane(runtime: runtime), let record = panes[pane] else { continue }
                guard data.isEmpty == false else { continue }
                record.emulator.feed(data)
                presentationChanged = true
                let responses = record.emulator.takeResponses()
                if leasedRuntime == runtime, record.state.lease == .owned {
                    replies.append(contentsOf: responses.map { (runtime, $0) })
                }
            case .overflow(let runtime):
                guard let pane = pane(runtime: runtime) else { continue }
                if panes[pane]?.state.overflowed != true {
                    panes[pane]?.state.overflowed = true
                    presentationChanged = true
                }
            case .exited(let runtime, let status):
                guard let pane = pane(runtime: runtime) else { continue }
                if panes[pane]?.state.running != false || panes[pane]?.state.exitStatus != status
                    || panes[pane]?.state.lease != .released {
                    presentationChanged = true
                }
                panes[pane]?.state.running = false
                panes[pane]?.state.exitStatus = status
                panes[pane]?.state.lease = .released
                if leasedRuntime == runtime { leasedRuntime = nil }
            case .inputOwner(let runtime, let owned):
                guard let pane = pane(runtime: runtime) else { continue }
                if owned {
                    // The host broadcasts only that an owner exists, not which
                    // client owns it. Only our successful acquire RPC grants
                    // local write authority.
                    if leasedRuntime != runtime {
                        presentationChanged = presentationChanged || panes[pane]?.state.lease != .readOnly
                        panes[pane]?.state.lease = .readOnly
                    }
                } else {
                    // Notifications do not carry a lease generation. A queued
                    // release from an earlier focus epoch may arrive after a
                    // later acquire succeeded, so the successful acquire is
                    // authoritative while this client still claims ownership.
                    guard leasedRuntime != runtime else { continue }
                    presentationChanged = presentationChanged || panes[pane]?.state.lease != .readOnly
                    panes[pane]?.state.lease = .readOnly
                    if focusedPane == pane, panes[pane]?.state.running == true {
                        pendingInputAcquisitions.insert(pane)
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

    public func noteCanvas(width: Int, height: Int) {
        lock.lock()
        canvas = PaneRect(x: 0, y: 0, width: max(1, width), height: max(1, height))
        lock.unlock()
    }

    /// Records the content area of one terminal. It does not perform an RPC or
    /// resize during SwiftTUI's render pass.
    public func noteSize(of pane: PaneID, rows: Int, columns: Int, now: Date) {
        lock.lock()
        guard var record = panes[pane], connection == .connected else {
            lock.unlock()
            return
        }
        record.resize.record(rows: rows, columns: columns, now: now)
        panes[pane] = record
        lock.unlock()
    }

    /// Called by the app's single coalescing timer. Equal dimensions never
    /// produce another RPC; changed dimensions wait for the debounce window.
    public func processPendingWork(now: Date = Date()) {
        var requests: [(UUID, Int, Int)] = []
        var acquisitions: [PaneID] = []
        lock.lock()
        guard connection == .connected else {
            lock.unlock()
            return
        }
        for pane in panes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard var record = panes[pane], let size = record.resize.flush(now: now) else { continue }
            record.emulator.resize(columns: size.columns, rows: size.rows)
            requests.append((record.state.runtime, size.rows, size.columns))
            panes[pane] = record
        }
        if requests.isEmpty == false { markPresentationChangedLocked() }
        acquisitions = pendingInputAcquisitions
            .filter { $0 == focusedPane && panes[$0]?.state.lease == .readOnly }
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        pendingInputAcquisitions.removeAll(keepingCapacity: true)
        lock.unlock()

        let pendingRequests = requests
        let pendingAcquisitions = acquisitions
        if pendingRequests.isEmpty == false {
            terminalQueue.async { [weak self] in
                guard let self, self.canIssueCommands() else { return }
                for (runtime, rows, columns) in pendingRequests {
                    switch self.client.resize(runtime, rows: rows, columns: columns) {
                    case .success:
                        break
                    case .failure(.disconnected):
                        self.markDisconnected()
                        return
                    case .failure(.unavailable):
                        self.markRuntimeExited(runtime)
                    case .failure:
                        break
                    }
                }
            }
        }
        if pendingAcquisitions.isEmpty == false {
            terminalQueue.async { [weak self] in
                guard let self, self.canIssueCommands() else { return }
                for pane in pendingAcquisitions { self.acquire(pane) }
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
            tree: tree,
            focused: focusedPane,
            panes: panes.mapValues(\.state),
            mode: mode,
            launcher: launcher,
            runtimeCount: panes.values.filter(\.state.running).count,
            presentationRevision: presentationRevision,
            shouldExit: shouldExit
        )
    }

    public func terminalFrame(for pane: PaneID) -> TerminalFrame? {
        lock.lock()
        defer { lock.unlock() }
        return panes[pane]?.emulator.frame()
    }

    public func terminalSize(for pane: PaneID) -> (rows: Int, columns: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return panes[pane]?.resize.effectiveSize
    }

    /// Runs during structured application cleanup. It never cancels a runtime
    /// or closes the workspace.
    public func detachSession() {
        let lease: UUID?
        let subscriptions: [UUID]
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
        pendingInputAcquisitions.removeAll()
        subscriptions = panes.values.filter(\.state.subscribed).map(\.state.runtime)
        for key in panes.keys {
            panes[key]?.state.lease = .released
            panes[key]?.state.subscribed = false
        }
        markPresentationChangedLocked()
        lock.unlock()

        // Drain terminal RPCs before closing their dedicated host connection,
        // then drain lifecycle work before unsubscribing and closing control.
        terminalQueue.sync {
            if let lease { _ = client.releaseInput(lease) }
        }
        commandQueue.sync {
            for runtime in subscriptions { _ = client.unsubscribe(runtime) }
            _ = client.detach()
        }
    }

    private func perform(_ command: TUICommand, now: Date) {
        guard canIssueCommands() else { return }
        switch command {
        case .splitVertical:
            split(.vertical, now: now)
        case .splitHorizontal:
            split(.horizontal, now: now)
        case .focus, .send:
            break // Routed on the ordered input worker by `handle`.
        case .closePane:
            closeFocused()
        case .newRuntime, .help, .dismissOverlay:
            break
        case .detach:
            break
        case .launch(let choice):
            split(.vertical, choice: choice, now: now)
        }
    }

    private func split(_ axis: SplitAxis, choice: RuntimeLaunchChoice? = nil, now: Date) {
        guard let selected = choice ?? launcher.first else { return }
        let pane = PaneID()
        let previousFocus: PaneID?
        let startingFocusRevision: UInt64
        let currentTree: PaneTree
        let prospective: PaneTree
        let rows: Int
        let columns: Int
        lock.lock()
        guard connection == .connected, shouldExit == false else {
            lock.unlock()
            return
        }
        previousFocus = focusedPane
        startingFocusRevision = focusRevision
        currentTree = tree
        if let current = focusedPane {
            guard case .success(let next) = tree.splitting(current, axis: axis, inserted: pane) else {
                lock.unlock()
                return
            }
            prospective = next
        } else if tree.isEmpty {
            prospective = .leaf(pane)
        } else {
            lock.unlock()
            return
        }
        let rect = PaneLayout.frames(of: prospective, in: canvas)[pane]
        (rows, columns) = rect.map(Self.terminalDimensions(in:)) ?? (initialRows, initialColumns)
        lock.unlock()

        guard case .success(let runtime) = client.launchRuntime(
            executable: selected.executable,
            arguments: selected.arguments,
            hook: selected.hook,
            rows: rows,
            columns: columns
        ) else { return }

        lock.lock()
        let detached = didDetach || shouldExit || connection != .connected
        guard detached == false, tree == currentTree else {
            lock.unlock()
            // A launch that races UI detach belongs to the workspace now. Keep
            // it alive so the next TUI invocation can rediscover it.
            if detached == false { _ = client.cancelRuntime(runtime.id) }
            return
        }
        tree = prospective
        var record = makeRecord(pane: pane, runtime: runtime, rows: rows, columns: columns)
        record.state.title = selected.title
        panes[pane] = record
        markPresentationChangedLocked()
        lock.unlock()

        switch bind(pane, runtime: runtime.id) {
        case .success:
            focusNewPaneIfUnchanged(pane, since: startingFocusRevision)
        case .failure:
            rollbackNewPane(pane, restoring: previousFocus)
            _ = client.cancelRuntime(runtime.id)
        }
    }

    private func rollbackNewPane(_ pane: PaneID, restoring previousFocus: PaneID?) {
        lock.lock()
        let runtime = panes[pane]?.state.runtime
        let subscribed = panes[pane]?.state.subscribed == true
        pendingInputAcquisitions.remove(pane)
        panes[pane] = nil
        if case .success(let closed) = tree.closing(pane) {
            tree = closed.tree
        }
        let next = focusedPane.flatMap { tree.contains($0) ? $0 : nil }
            ?? previousFocus.flatMap { tree.contains($0) ? $0 : nil }
            ?? tree.firstLeaf
        setFocusedPaneLocked(next)
        markPresentationChangedLocked()
        lock.unlock()
        if subscribed, let runtime { _ = client.unsubscribe(runtime) }
    }

    private func closeFocused() {
        let target: PaneID?
        let runtime: UUID?
        let running: Bool
        lock.lock()
        target = focusedPane
        if let target, let record = panes[target] {
            runtime = record.state.runtime
            running = record.state.running
        } else {
            runtime = nil
            running = false
        }
        lock.unlock()
        guard let target, let runtime else { return }

        if running {
            switch client.cancelRuntime(runtime) {
            case .success:
                break
            case .failure(.unavailable):
                guard runtimeIsStopped(runtime) else { return }
            case .failure(.disconnected):
                markDisconnected()
                return
            case .failure:
                return
            }
        }

        _ = client.unsubscribe(runtime)

        lock.lock()
        let focusBeforeClose = focusedPane
        pendingInputAcquisitions.remove(target)
        panes[target] = nil
        if case .success(let closed) = tree.closing(target) {
            tree = closed.tree
            let preservedFocus = focusBeforeClose.flatMap { tree.contains($0) ? $0 : nil }
            setFocusedPaneLocked(preservedFocus ?? closed.focus)
            markPresentationChangedLocked()
        }
        lock.unlock()
    }

    private func runtimeIsStopped(_ runtime: UUID) -> Bool {
        switch client.listRuntimes() {
        case .failure(.disconnected):
            markDisconnected()
            return false
        case .failure:
            return false
        case .success(let runtimes):
            return runtimes.first(where: { $0.id == runtime })?.running != true
        }
    }

    private func focusedRuntimeForInput() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard connection == .connected, shouldExit == false, didDetach == false,
              let pane = focusedPane, let record = panes[pane], record.state.running
        else { return nil }
        return record.state.runtime
    }

    private func send(_ bytes: Data, to runtime: UUID) {
        guard bytes.isEmpty == false else { return }
        lock.lock()
        let connected = connection == .connected && shouldExit == false && didDetach == false
        let ownsInput = leasedRuntime == runtime
        let pane = pane(runtime: runtime)
        let record = pane.flatMap { panes[$0] }
        lock.unlock()
        guard connected, ownsInput, let record, record.state.running else { return }
        switch client.write(runtime, bytes: bytes) {
        case .success:
            break
        case .failure(.busy):
            lock.lock()
            var presentationChanged = false
            if panes[record.state.pane]?.state.runtime == runtime {
                presentationChanged = panes[record.state.pane]?.state.lease != .readOnly
                panes[record.state.pane]?.state.lease = .readOnly
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

    private func moveFocus(_ direction: FocusDirection) {
        lock.lock()
        guard let current = focusedPane else {
            lock.unlock()
            return
        }
        let frames = PaneLayout.frames(of: tree, in: canvas)
        let next = PaneLayout.focus(from: current, direction: direction, frames: frames)
        lock.unlock()
        guard let next, next != current else { return }
        focus(next)
    }

    private func bind(_ pane: PaneID, runtime: UUID) -> Result<Void, WorkspaceTUIClientError> {
        switch client.subscribe(runtime) {
        case .success:
            lock.lock()
            panes[pane]?.state.subscribed = true
            lock.unlock()
            return .success(())
        case .failure(let error):
            if error == .disconnected {
                markDisconnected()
            }
            lock.lock()
            panes[pane]?.state.subscribed = false
            lock.unlock()
            return .failure(error)
        }
    }

    private func focus(_ pane: PaneID) {
        lock.lock()
        guard connection == .connected, tree.contains(pane) else {
            lock.unlock()
            return
        }
        setFocusedPaneLocked(pane)
        lock.unlock()
    }

    /// A split should focus its new pane only if the user has not moved focus
    /// while the host was launching and subscribing the runtime.
    private func focusNewPaneIfUnchanged(_ pane: PaneID, since revision: UInt64) {
        lock.lock()
        guard connection == .connected, tree.contains(pane), focusRevision == revision else {
            lock.unlock()
            return
        }
        setFocusedPaneLocked(pane)
        lock.unlock()
    }

    /// Call with `lock` held. Queue insertion is in the same critical section
    /// as the focus mutation, preserving focus/RPC order across UI and lifecycle
    /// callbacks.
    private func setFocusedPaneLocked(_ pane: PaneID?) {
        let changed = focusedPane != pane
        if changed {
            focusRevision &+= 1
            markPresentationChangedLocked()
        }
        if focusedPane != pane,
           let leasedRuntime,
           let oldPane = self.pane(runtime: leasedRuntime) {
            panes[oldPane]?.state.lease = .released
        }
        focusedPane = pane
        terminalQueue.async { [weak self] in
            guard let self, self.canIssueCommands() else { return }
            self.transferInputLease(to: pane)
        }
    }

    private func transferInputLease(to pane: PaneID?) {
        lock.lock()
        guard connection == .connected, shouldExit == false, didDetach == false else {
            lock.unlock()
            return
        }
        let targetRuntime = pane.flatMap { panes[$0] }.flatMap { $0.state.running ? $0.state.runtime : nil }
        let oldRuntime = leasedRuntime
        guard oldRuntime != targetRuntime else {
            if let pane, let targetRuntime, panes[pane]?.state.runtime == targetRuntime {
                if panes[pane]?.state.lease != .owned { markPresentationChangedLocked() }
                panes[pane]?.state.lease = .owned
            }
            lock.unlock()
            return
        }
        leasedRuntime = nil
        if let oldRuntime, let oldPane = self.pane(runtime: oldRuntime) {
            if panes[oldPane]?.state.lease != .released { markPresentationChangedLocked() }
            panes[oldPane]?.state.lease = .released
        }
        lock.unlock()

        if let oldRuntime {
            if case .failure(.disconnected) = client.releaseInput(oldRuntime) {
                markDisconnected()
                return
            }
        }
        if let pane, targetRuntime != nil { acquire(pane, requireFocus: false) }
    }

    private func acquire(_ pane: PaneID, requireFocus: Bool = true) {
        lock.lock()
        guard connection == .connected, requireFocus == false || focusedPane == pane,
              let record = panes[pane], record.state.running else {
            lock.unlock()
            return
        }
        let runtime = record.state.runtime
        lock.unlock()

        switch client.acquireInput(runtime) {
        case .success:
            lock.lock()
            let stillAvailable = connection == .connected && tree.contains(pane)
                && (requireFocus == false || focusedPane == pane)
                && panes[pane]?.state.runtime == runtime && panes[pane]?.state.running == true
            if stillAvailable {
                if panes[pane]?.state.lease != .owned { markPresentationChangedLocked() }
                panes[pane]?.state.lease = .owned
                leasedRuntime = runtime
            }
            lock.unlock()
            if stillAvailable == false { _ = client.releaseInput(runtime) }
        case .failure(.busy):
            lock.lock()
            if focusedPane == pane, panes[pane]?.state.runtime == runtime {
                if panes[pane]?.state.lease != .readOnly { markPresentationChangedLocked() }
                panes[pane]?.state.lease = .readOnly
            }
            lock.unlock()
        case .failure(.disconnected):
            markDisconnected()
        case .failure:
            lock.lock()
            if focusedPane == pane, panes[pane]?.state.runtime == runtime {
                if panes[pane]?.state.lease != .readOnly { markPresentationChangedLocked() }
                panes[pane]?.state.lease = .readOnly
            }
            lock.unlock()
        }
    }

    private func makeRecord(pane: PaneID, runtime: ListedRuntime, rows: Int, columns: Int) -> TerminalPaneModel {
        var resize = ResizeCoalescer()
        resize.recordLaunch(rows: rows, columns: columns)
        return TerminalPaneModel(
            state: TerminalPaneState(
                pane: pane,
                runtime: runtime.id,
                title: runtime.hook ?? "runtime",
                running: runtime.running
            ),
            emulator: emulators.make(columns: columns, rows: rows),
            resize: resize
        )
    }

    private func pane(runtime: UUID) -> PaneID? {
        panes.first { $0.value.state.runtime == runtime }?.key
    }

    private func markDisconnected() {
        lock.lock()
        let changed = connection != .disconnected
            || panes.values.contains { $0.state.lease != .readOnly || $0.state.subscribed }
        connection = .disconnected
        leasedRuntime = nil
        pendingInputAcquisitions.removeAll()
        for key in panes.keys {
            panes[key]?.state.lease = .readOnly
            panes[key]?.state.subscribed = false
        }
        if changed { markPresentationChangedLocked() }
        lock.unlock()
    }

    private func markRuntimeExited(_ runtime: UUID) {
        lock.lock()
        guard let pane = pane(runtime: runtime) else {
            lock.unlock()
            return
        }
        let changed = panes[pane]?.state.running != false || panes[pane]?.state.exitStatus != nil
            || panes[pane]?.state.lease != .released
        panes[pane]?.state.running = false
        panes[pane]?.state.exitStatus = nil
        panes[pane]?.state.lease = .released
        if leasedRuntime == runtime { leasedRuntime = nil }
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

    private static func terminalDimensions(in rect: PaneRect) -> (rows: Int, columns: Int) {
        // PaneTree frames include the two-cell border; the title consumes one
        // additional row. The global header is outside this rect.
        let columns = Self.bound(rect.width - 2)
        let rows = Self.bound(rect.height - 3)
        return (rows, columns)
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
    public var tree: PaneTree
    public var focused: PaneID?
    public var panes: [PaneID: TerminalPaneState]
    public var mode: CommandMode
    public var launcher: [RuntimeLaunchChoice]
    public var runtimeCount: Int
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
