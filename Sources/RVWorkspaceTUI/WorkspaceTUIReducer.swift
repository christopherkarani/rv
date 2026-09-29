import Foundation
import RVDomain

struct PaneBindingKey: Hashable, Sendable {
    var pane: PaneID
    var runtime: UUID
    var generation: UInt64
}

/// One deterministic navigator row: an input-lease action for the focused
/// pane, a tab to activate, or an unplaced runtime to attach.
public enum NavigatorItem: Equatable, Sendable {
    case acquireInput
    case releaseInput
    case tab(id: TabID, title: String, index: Int)
    case runtime(id: UUID, label: String)
}

/// Closed lifecycle for one workspace shell session.
///
/// The previous model tracked this as `didConnect` / `connection` /
/// `didDetach` flags, which admitted impossible combinations. One enum keeps
/// every documented behavior while making invalid states unrepresentable:
/// - `neverConnected`: `connect()` has never succeeded. A later `connect()`
///   retries the describe/list query instead of failing fast.
/// - `connected`: the host is reachable; terminal I/O is allowed.
/// - `disconnected`: a query, RPC, or host event reported the host gone.
/// - `detached`: `detachSession()` ran. No transition leaves this state, and
///   completions that race detach reduce to no-ops (an orphaned acquire
///   still emits `.release` so the host drops the stale lease).
enum WorkspaceTUILifecycle: Equatable, Sendable {
    case neverConnected
    case connected
    case disconnected
    case detached
}

/// Decision state for one workspace shell. Every field the reducer reads or
/// writes lives here; the runtime owns the client, the emulator object, the
/// lock, and the queues, and executes the effects the reducer returns.
struct WorkspaceTUIState: Equatable, Sendable {
    struct AttachedTerminal: Equatable, Sendable {
        var state: WorkspaceTerminalState
        var resize: ResizeCoalescer
    }

    struct ViewSize: Equatable, Sendable {
        var rows: Int
        var columns: Int
    }

    var lifecycle: WorkspaceTUILifecycle
    var summary: WorkspaceTUISummary
    /// Launcher choices are configuration: set at init, never mutated.
    var launcher: [RuntimeLaunchChoice]
    /// The launcher row the auto-opened shell uses. Configuration: set at
    /// init from the operator default, never mutated.
    var defaultShellID: String
    /// Initial dimensions are configuration: set at init, never mutated.
    var initialRows: Int
    var initialColumns: Int
    var mode: CommandMode
    var view: WorkspaceView
    var terminals: [PaneID: AttachedTerminal]
    /// The runtime this client last acquired input for. A successful acquire
    /// RPC is authoritative over queued lease notifications (see
    /// `.inputOwner` handling below).
    var leasedBindings: Set<PaneBindingKey>
    var retryAcquirePanes: Set<PaneID>
    /// Panes whose overflow resubscribe raced the host-side drop and must
    /// re-attach on tick. Acquire retries stay separate: acquire fails
    /// closed until a subscription exists.
    var retrySubscribePanes: Set<PaneID> = []
    var shouldExit: Bool
    var initialLaunchRequested: Bool
    var viewSize: ViewSize?
    var presentationRevision: UInt64
    var feedback: String?
    var feedbackTicks: Int

    struct PendingLaunch: Equatable, Sendable {
        var binding: PaneBindingKey
        var terminal: AttachedTerminal
    }
    var pendingLaunches: [PaneID: PendingLaunch] = [:]
    /// Typeahead held while a pane's input lease is in flight. The binding
    /// pins the exact runtime generation the bytes belong to, so a
    /// replacement or reattach can never flush stale bytes into a new
    /// runtime. Bounded to one host write per pane.
    struct PendingPaneInput: Equatable, Sendable {
        var binding: PaneBindingKey
        var bytes: Data
    }
    static let maximumPendingInputBytes = 4096
    /// Subscription heartbeat cadence. A probe is one cheap RPC per pane
    /// (healthy subscriptions fail fast in-memory); it catches silent
    /// overflow drops no event announced.
    static let subscriptionProbeInterval: TimeInterval = 5
    /// Last heartbeat fire. Nil probes on the first connected tick.
    var lastSubscriptionProbeAt: Date? = nil
    var pendingInput: [PaneID: PendingPaneInput] = [:]
    var replayBatches: [PaneID: UUID] = [:]
    var recentOutputOnly: Set<PaneID> = []
    /// RV viewport anchors: lines above live output per pane, 0 when live.
    var scrollAnchors: [PaneID: Int] = [:]
    /// Binding generation captured when scroll mode opened, for staleness.
    var scrollGenerations: [PaneID: UInt64] = [:]
    /// Last inventoried host runtimes, sorted by id. References only.
    var knownRuntimes: [ListedRuntime] = []
    /// Rows built when the navigator opened, rebuilt on inventory refresh.
    var navigatorItems: [NavigatorItem] = []
    /// Leases held when the host went away. Reconnect restores these (or
    /// observes) after reconciling against fresh inventory.
    var preDisconnectLeases: Set<PaneBindingKey> = []
    var reconnectAttempt: Int = 0
    var reconnectInflight: Bool = false
    var reconnectFiresAt: Date? = nil

    var activePaneID: PaneID? { view.activeTab?.focusedPaneID }

    var activeBindingKey: PaneBindingKey? {
        activePaneID.flatMap(bindingKey(for:))
    }

    func bindingKey(for paneID: PaneID) -> PaneBindingKey? {
        guard let binding = view.panes[paneID]?.binding else { return nil }
        return PaneBindingKey(pane: paneID, runtime: binding.runtime.rawValue, generation: binding.generation)
    }

    func paneID(for runtime: UUID) -> PaneID? {
        view.panes.first { $0.value.binding?.runtime.rawValue == runtime }?.key
    }

    mutating func assignTerminal(_ value: AttachedTerminal?, to paneID: PaneID) {
        guard let oldPane = view.panes[paneID] else { return }
        if let oldBinding = oldPane.binding, value?.state.runtime != oldBinding.runtime.rawValue {
            leasedBindings.remove(PaneBindingKey(
                pane: paneID, runtime: oldBinding.runtime.rawValue, generation: oldBinding.generation
            ))
        }
        terminals[paneID] = value
        pendingInput[paneID] = nil
        let binding: RuntimeBinding?
        let lifecycle: WorkspacePaneLifecycle
        let outcome: WorkspacePaneOutcome?
        if let value {
            let previous = oldPane.binding
            let generation = previous?.runtime.rawValue == value.state.runtime
                ? previous?.generation ?? 1 : (previous?.generation ?? 0) &+ 1
            binding = RuntimeBinding(
                workspace: WorkspaceSessionID(rawValue: summary.workspace),
                runtime: RuntimeSessionID(rawValue: value.state.runtime),
                generation: generation
            )
            lifecycle = value.state.running ? .running : .exited
            outcome = value.state.exitStatus.map(WorkspacePaneOutcome.exited) ?? oldPane.lastOutcome
        } else {
            binding = nil
            lifecycle = .empty
            outcome = oldPane.lastOutcome
        }
        view = view.updatingPane(WorkspacePane(
            id: paneID, userTitle: oldPane.userTitle, binding: binding,
            lifecycle: lifecycle, lastOutcome: outcome
        )) ?? view
    }

    mutating func updatePane(_ paneID: PaneID, _ update: (inout WorkspacePane) -> Void) {
        guard var pane = view.panes[paneID] else { return }
        update(&pane)
        view = view.updatingPane(pane) ?? view
    }

    /// Holds typeahead for a lease that has not landed yet. Bytes past one
    /// host write are dropped while the lease is out; the pane keeps
    /// responding instead of wedging on an unbounded queue. Returns true
    /// when bytes were dropped so the caller can surface the loss: a
    /// truncated paste is data loss, never a quiet cap.
    mutating func queuePendingInput(_ bytes: Data, for binding: PaneBindingKey) -> Bool {
        guard bytes.isEmpty == false else { return false }
        var current = pendingInput[binding.pane].flatMap { $0.binding == binding ? $0.bytes : nil } ?? Data()
        let room = Self.maximumPendingInputBytes - min(current.count, Self.maximumPendingInputBytes)
        let admitted = bytes.prefix(room)
        current.append(admitted)
        pendingInput[binding.pane] = PendingPaneInput(binding: binding, bytes: current)
        let truncated = admitted.count < bytes.count
        if truncated {
            feedback = "Typeahead full; dropped \(bytes.count - admitted.count) bytes"
            feedbackTicks = 60
        }
        return truncated
    }

    /// Takes bytes queued for exactly this binding. Anything else stays put.
    mutating func takePendingInput(for binding: PaneBindingKey) -> Data? {
        guard pendingInput[binding.pane]?.binding == binding,
              let bytes = pendingInput[binding.pane]?.bytes, bytes.isEmpty == false else { return nil }
        pendingInput[binding.pane] = nil
        return bytes
    }

    /// Compatibility projection for the first visible pane. WorkspaceView and
    /// the pane-keyed presentation map are the only stored presentation state.
    var terminal: AttachedTerminal? {
        get {
            guard let activePaneID else { return nil }
            return terminals[activePaneID]
        }
        set {
            guard let activePaneID else { return }
            assignTerminal(newValue, to: activePaneID)
        }
    }

    var leasedRuntime: UUID? {
        get { activeBindingKey.flatMap { leasedBindings.contains($0) ? $0.runtime : nil } }
        set {
            guard let key = activeBindingKey else { return }
            if newValue == key.runtime { leasedBindings.insert(key) }
            else { leasedBindings.remove(key) }
        }
    }

    var retryAcquire: Bool {
        get { activePaneID.map(retryAcquirePanes.contains) ?? false }
        set {
            guard let pane = activePaneID else { return }
            if newValue { retryAcquirePanes.insert(pane) }
            else { retryAcquirePanes.remove(pane) }
        }
    }

    init(
        lifecycle: WorkspaceTUILifecycle,
        summary: WorkspaceTUISummary,
        launcher: [RuntimeLaunchChoice],
        defaultShellID: String = RuntimeLaunchChoice.shellID,
        initialRows: Int,
        initialColumns: Int,
        mode: CommandMode,
        terminal: AttachedTerminal?,
        leasedRuntime: UUID?,
        retryAcquire: Bool,
        shouldExit: Bool,
        initialLaunchRequested: Bool,
        viewSize: ViewSize?,
        presentationRevision: UInt64,
        paneID: PaneID = PaneID(),
        tabID: TabID = TabID(),
        viewID: ViewID = ViewID(),
        restoredView: WorkspaceView? = nil
    ) {
        self.lifecycle = lifecycle
        self.summary = summary
        self.launcher = launcher
        self.defaultShellID = defaultShellID
        self.initialRows = initialRows
        self.initialColumns = initialColumns
        self.mode = mode
        self.view = restoredView ?? WorkspaceView(
            id: viewID,
            tabs: [WorkspaceTab(id: tabID, tree: .leaf(paneID), focusedPaneID: paneID)],
            activeTabID: tabID,
            panes: [paneID: WorkspacePane(id: paneID)]
        )
        self.terminals = [:]
        self.leasedBindings = []
        self.retryAcquirePanes = retryAcquire ? [paneID] : []
        self.shouldExit = shouldExit
        self.initialLaunchRequested = initialLaunchRequested || restoredView != nil
        self.viewSize = viewSize
        self.presentationRevision = presentationRevision
        self.feedback = nil
        self.feedbackTicks = 0
        // A nil seed must not flow through the clearing setters:
        // `terminal = nil` resolves to the focused pane and would wipe
        // its restored binding before reconcile ever sees it.
        if let terminal { self.terminal = terminal }
        if let leasedRuntime { self.leasedRuntime = leasedRuntime }
    }
}

/// Inputs the reducer decides on. UI/host inputs and RPC completions share one
/// enum so a scripted event sequence fully determines the transitions.
enum WorkspaceTUIReducerEvent: Equatable, Sendable {
    case connectRequested
    case connectQuery(described: WorkspaceTUISummary, runtimes: [ListedRuntime])
    case connectQueryFailed
    case launchDefaultRequested
    case ensureSucceeded(target: PrefixTarget, runtime: ListedRuntime, shell: RuntimeLaunchChoice)
    case ensureFailed(target: PrefixTarget, error: WorkspaceTUIError, profileID: String?)
    case key(TUIKey)
    case paste(String)
    case runCommandResolved(target: PrefixTarget, choice: RuntimeLaunchChoice)
    case runCommandFailed(target: PrefixTarget, message: String)
    case sendDue(binding: PaneBindingKey, bytes: Data)
    case emulatorSendDue(binding: PaneBindingKey, bytes: Data)
    case launchDue(target: PrefixTarget, choice: RuntimeLaunchChoice)
    case launchQuerySucceeded(target: PrefixTarget, choice: RuntimeLaunchChoice, runtime: ListedRuntime, rows: Int, columns: Int)
    case launchQueryFailed(target: PrefixTarget, choice: RuntimeLaunchChoice, error: WorkspaceTUIError)
    case inventoryRefreshed(terminals: [ListedRuntime])
    case reconnectFailed(error: WorkspaceTUIError)
    case reconnectSucceeded(terminals: [ListedRuntime])
    case hostEvents([WorkspaceTUIEvent])
    case emulatorResponded(binding: PaneBindingKey, responses: [Data])
    case sizeNoted(rows: Int, columns: Int, now: Date)
    case paneSizeNoted(pane: PaneID, rows: Int, columns: Int, now: Date)
    case viewportNoted(rows: Int, columns: Int)
    case notice(String)
    case tick(now: Date)
    case hostDisconnected
    case writeCompleted(binding: PaneBindingKey, bytes: Data, outcome: TUIRPCOutcome)
    case acquireCompleted(binding: PaneBindingKey, outcome: TUIRPCOutcome)
    case releaseInputCompleted(binding: PaneBindingKey, outcome: TUIRPCOutcome)
    case resizeCompleted(binding: PaneBindingKey, rows: Int, columns: Int, outcome: TUIRPCOutcome, now: Date)
    case attachCompleted(binding: PaneBindingKey, context: TUIAttachContext, outcome: SessionAttachOutcome)
    case detachRequested
}

/// One runtime action for the shell to execute. Effects never dispatch
/// themselves; the runtime owns queue choice and lock discipline.
enum TUIRuntimeEffect: Equatable, Sendable {
    /// Synchronous inventory query. The runtime feeds the result back as
    /// `.connectQuery` or `.connectQueryFailed`.
    case queryConnect
    /// Synchronous ensure-or-reuse query for the default shell.
    case ensureShell(target: PrefixTarget, choice: RuntimeLaunchChoice, rows: Int, columns: Int)
    /// Key or emulator input to deliver on the terminal queue, re-gated there
    /// by `.sendDue` before the write RPC runs.
    case queueSend(binding: PaneBindingKey, bytes: Data)
    case queueEmulatorResponse(binding: PaneBindingKey, bytes: Data)
    case queueKey(binding: PaneBindingKey, key: TUIKey)
    case queuePaste(binding: PaneBindingKey, text: String)
    case resolveRunCommand(target: PrefixTarget, input: String)
    /// Launcher choice to run on the command queue, re-gated there by
    /// `.launchDue` before the launch RPC runs.
    case queueLaunch(target: PrefixTarget, choice: RuntimeLaunchChoice)
    /// Synchronous launch query. The runtime feeds the result back as
    /// `.launchQuerySucceeded` or `.launchQueryFailed`.
    case launchQuery(target: PrefixTarget, choice: RuntimeLaunchChoice, rows: Int, columns: Int)
    case attach(binding: PaneBindingKey, context: TUIAttachContext)
    case observe(binding: PaneBindingKey, context: TUIAttachContext)
    case reconnectQuery
    case restartEvents
    case acquire(binding: PaneBindingKey)
    case releaseInput(binding: PaneBindingKey)
    case refreshInventory
    case release(runtime: UUID)
    case write(binding: PaneBindingKey, bytes: Data)
    case resize(binding: PaneBindingKey, rows: Int, columns: Int)
    case cancel(runtime: UUID)
    case detach
    case createEmulator(binding: PaneBindingKey, rows: Int, columns: Int)
    case feedEmulator(binding: PaneBindingKey, data: Data)
    case resizeEmulator(binding: PaneBindingKey, rows: Int, columns: Int)
    case dropEmulator(binding: PaneBindingKey)
}

/// Why an attach was issued. Each origin handles attach failure
/// differently, so the context travels with the effect to its completion.
enum TUIAttachContext: Equatable, Sendable {
    /// `connect()`: a refused attach renders the terminal read-only
    /// without acquiring. The seam pairs subscribe with its acquire, so
    /// unlike the pre-seam client there is no acquire after a refusal.
    case connect
    /// `launchDefaultRuntimeIfEmpty()`: failure marks the terminal
    /// "(unavailable)" and read-only without acquiring.
    case ensure
    /// Replacement launch: a failed attach leaves the prior pane output and
    /// the newly created runtime remains host-owned for later discovery.
    case launch
    /// Reconnect reconcile: a failed attach marks the pane missing while its
    /// last output stays on screen for navigator retry.
    case reconnect
    /// Overflow recovery: a failed attach retries once on tick. The pane
    /// keeps its last output and the skipped-output indicator until it
    /// lands.
    case resubscribe
    /// The one-shot tick retry of a failed resubscribe. A second failure
    /// stays quiet: the race it covers (host-side drop removal) resolves
    /// in microseconds, so a repeat means the runtime is gone and further
    /// RPCs would only spam. A later overflow re-arms a fresh attempt.
    case resubscribeRetry
    /// Subscription heartbeat: success means the host had silently dropped
    /// us (the subscription is live again); failure means the existing
    /// subscription is healthy and is a no-op.
    case probe
}

/// Outcome of one terminal-queue RPC, mapped from `WorkspaceTUIError`.
enum TUIRPCOutcome: Equatable, Sendable {
    case ok
    case busy
    case disconnected
    case unavailable
    case rejected

    static func from(_ result: Result<Void, WorkspaceTUIError>) -> Self {
        switch result {
        case .success: .ok
        case .failure(.busy): .busy
        case .failure(.disconnected): .disconnected
        case .failure(.unavailable): .unavailable
        case .failure(.rejected), .failure(.resourceProfileUnavailable),
            .failure(.resourceStagingFailed), .failure(.incompatibleHost): .rejected
        }
    }
}

struct WorkspaceTUITransition: Equatable, Sendable {
    var state: WorkspaceTUIState
    var effects: [TUIRuntimeEffect]
}

/// Pure TUI decisions: `State + Event -> (State, [Effect])`.
///
/// Every branch mirrors the previous `WorkspaceTUIModel` method's behavior,
/// including its presentation-revision bumps. The reducer never touches the
/// client, the emulator, a lock, or a queue.
enum WorkspaceTUIReducer {
    static func reduce(_ state: WorkspaceTUIState, _ event: WorkspaceTUIReducerEvent) -> WorkspaceTUITransition {
        var next = state
        var effects: [TUIRuntimeEffect] = []
        var presentationChanged = false
        switch event {
        case .connectRequested:
            // Repeated calls are harmless and never create another runtime.
            guard next.lifecycle == .neverConnected else { break }
            effects = [.queryConnect]

        case .connectQuery(let described, let runtimes):
            guard next.lifecycle == .neverConnected else { break }
            next.summary = described
            next.lifecycle = .connected
            next.knownRuntimes = runtimes.sorted { $0.id.uuidString < $1.id.uuidString }
            presentationChanged = true
            let available = Dictionary(uniqueKeysWithValues: runtimes.filter(\.terminal).map { ($0.id, $0) })
            for paneID in next.view.panes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard let saved = next.view.panes[paneID]?.binding else { continue }
                guard saved.workspace.rawValue == described.workspace,
                      let runtime = available[saved.runtime.rawValue] else {
                    next.updatePane(paneID) { $0.lifecycle = .missing }
                    continue
                }
                let rows = runtime.rows.map(Self.bound) ?? next.initialRows
                let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
                next.assignTerminal(Self.attached(
                    runtime: runtime, title: runtime.hook ?? "runtime", rows: rows, columns: columns
                ), to: paneID)
                if let binding = next.bindingKey(for: paneID) {
                    effects.append(.createEmulator(binding: binding, rows: rows, columns: columns))
                    effects.append(.attach(binding: binding, context: .connect))
                }
            }
            if next.view.panes.values.allSatisfy({ $0.binding == nil }),
               let paneID = next.activePaneID,
               let runtime = runtimes.filter(\.terminal)
                   .sorted(by: { $0.id.uuidString < $1.id.uuidString }).first {
                let rows = runtime.rows.map(Self.bound) ?? next.initialRows
                let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
                next.assignTerminal(Self.attached(
                    runtime: runtime, title: runtime.hook ?? "runtime", rows: rows, columns: columns
                ), to: paneID)
                if let binding = next.bindingKey(for: paneID) {
                    effects.append(.createEmulator(binding: binding, rows: rows, columns: columns))
                    effects.append(.attach(binding: binding, context: .connect))
                }
            }

        case .connectQueryFailed:
            guard next.lifecycle == .neverConnected else { break }
            // A failed first query stays retryable: the lifecycle deliberately
            // does not advance to `.disconnected`.
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)

        case .launchDefaultRequested:
            guard next.lifecycle == .connected, next.shouldExit == false,
                  next.terminal == nil, next.initialLaunchRequested == false else { break }
            next.initialLaunchRequested = true
            guard let shell = Self.defaultShell(next) else {
                next.mode = .launcher
                presentationChanged = true
                break
            }
            guard let target = Self.target(next) else { break }
            effects = [.ensureShell(target: target, choice: shell, rows: next.initialRows, columns: next.initialColumns)]

        case .ensureSucceeded(let target, let runtime, let shell):
            guard next.lifecycle == .connected, next.shouldExit == false,
                  Self.target(next) == target, next.terminal == nil else { break }
            let rows = runtime.rows.map(Self.bound) ?? next.initialRows
            let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
            let title: String
            if let hook = runtime.hook {
                title = next.launcher.first(where: { $0.hook == hook })?.title ?? hook
            } else {
                title = runtime.created ? shell.title : "runtime"
            }
            next.terminal = Self.attached(runtime: runtime, title: title, rows: rows, columns: columns)
            guard let binding = next.activeBindingKey else { break }
            presentationChanged = true
            effects = [
                .createEmulator(binding: binding, rows: rows, columns: columns),
                .attach(binding: binding, context: .ensure),
            ]

        case .ensureFailed(let target, let error, let profileID):
            guard next.lifecycle == .connected, Self.target(next) == target else { break }
            if error == .disconnected {
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                next.lifecycle = .disconnected
            } else if next.terminal == nil {
                // A failed auto-shell drops to the launcher; the denial
                // renders in the footer so the cause is not silent.
                let message = Self.launchFailureMessage(error, profileID: profileID)
                next.updatePane(target.pane) {
                    $0.lifecycle = .launchFailed
                    $0.lastOutcome = .launchFailed(message)
                }
                next.feedback = message
                next.feedbackTicks = 60
                next.mode = .launcher
                presentationChanged = true
            }

        case .key(let key):
            guard next.lifecycle != .detached, next.shouldExit == false else { break }
            if next.lifecycle == .disconnected, key == .enter, next.mode == .terminal {
                // Manual retry after the bounded schedule gave up. The next
                // tick schedules the attempt; nothing is sent to any runtime.
                next.reconnectAttempt = 0
                next.reconnectInflight = false
                next.reconnectFiresAt = nil
                next.feedback = "Reconnecting…"
                next.feedbackTicks = 60
                presentationChanged = true
                break
            }
            if case .prefix(let target) = next.mode,
               target != next.activePaneID.map({ PrefixTarget(pane: $0, generation: next.activeBindingKey?.generation) }) {
                next.mode = .terminal
                next.feedback = "Pane changed; command cancelled"
                next.feedbackTicks = 60
                presentationChanged = true
                break
            }
            if case .scroll(let pane) = next.mode, Self.scrollStale(pane, in: next) {
                next.mode = .terminal
                next.feedback = "Pane changed; scroll cancelled"
                next.feedbackTicks = 60
                presentationChanged = true
                break
            }
            if case .confirmCancel(let pane) = next.mode, next.view.panes[pane] == nil {
                next.mode = .terminal
                next.feedback = "Pane changed; cancelled"
                next.feedbackTicks = 60
                presentationChanged = true
                break
            }
            // The router consumes these positions into the next mode; capture
            // them before routing so activation resolves the right row/pane.
            let navigatorIndexBefore: Int?
            if case .navigator(let index) = next.mode { navigatorIndexBefore = index }
            else { navigatorIndexBefore = nil }
            let confirmPaneBefore: PaneID?
            if case .confirmCancel(let pane) = next.mode { confirmPaneBefore = pane }
            else { confirmPaneBefore = nil }
            let previousMode = next.mode
            let previousShouldExit = next.shouldExit
            let decision = CommandPrefix.route(
                key,
                mode: next.mode,
                launcher: next.launcher,
                directLauncherSelection: next.terminal?.state.running != true,
                target: next.activePaneID.map { PrefixTarget(pane: $0, generation: next.activeBindingKey?.generation) }
            )
            next.mode = decision.0
            if decision.1 == .detach {
                // SwiftTUI polls this state to leave TerminalRunner and
                // restore the local terminal. Detach itself performs no
                // blocking host RPC.
                next.shouldExit = true
            }
            if next.mode != previousMode || next.shouldExit != previousShouldExit {
                presentationChanged = true
            }
            switch decision.1 {
            case .sendKey(let input):
                if input == .enter, Self.bindingForInput(next) == nil,
                   let launch = Self.relaunchFocusedShell(into: &next) {
                    effects = [launch]
                    presentationChanged = true
                } else if let binding = Self.bindingForInput(next) {
                    effects = [.queueKey(binding: binding, key: input)]
                }
            case .send(let bytes):
                if let binding = Self.bindingForInput(next) {
                    effects = [.queueSend(binding: binding, bytes: bytes)]
                }
            case .openLauncher:
                next.mode = .launcher
                presentationChanged = true
            case .split(let axis):
                if let updated = next.view.splittingFocusedPane(axis: axis, in: Self.viewport(next)) {
                    next.view = updated
                    presentationChanged = true
                    if let target = Self.target(next), let shell = Self.defaultShell(next) {
                        next.updatePane(target.pane) { $0.lifecycle = .launching }
                        effects = [.queueLaunch(target: target, choice: shell)]
                    }
                } else {
                    next.feedback = "Not enough room to split pane"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .focus(let direction):
                if let tab = next.view.activeTab,
                   let geometry = PaneGeometry.solve(tab.tree, in: Self.viewport(next)),
                   let pane = geometry.focus(from: tab.focusedPaneID, toward: direction),
                   let updated = next.view.focusingPane(pane) {
                    next.view = updated
                    presentationChanged = true
                }
            case .newTab:
                if let updated = next.view.addingTab() {
                    next.view = updated
                    presentationChanged = true
                    if let target = Self.target(next), let shell = Self.defaultShell(next) {
                        next.updatePane(target.pane) { $0.lifecycle = .launching }
                        effects = [.queueLaunch(target: target, choice: shell)]
                    }
                } else {
                    next.feedback = "Pane limit reached"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .switchTab(let offset):
                if let updated = next.view.switchingTab(by: offset), updated != next.view {
                    next.view = updated
                    presentationChanged = true
                }
            case .closePane:
                if let pane = next.activePaneID, let tab = next.view.activeTab {
                    let geometry = PaneGeometry.solve(tab.tree, in: Self.viewport(next))
                        ?? PaneGeometry.solve(tab.tree, in: CellRect(
                            x: 0, y: 0, width: tab.tree.minimumOuterSize.width,
                            height: tab.tree.minimumOuterSize.height
                        ))
                    if let geometry, let updated = next.view.closingFocusedPane(using: geometry) {
                        if let binding = next.bindingKey(for: pane) {
                            if next.terminals[pane]?.state.subscribed == true
                                || next.leasedBindings.contains(binding) {
                                effects.append(.release(runtime: binding.runtime))
                            }
                            effects.append(.dropEmulator(binding: binding))
                            next.leasedBindings.remove(binding)
                        }
                        next.terminals.removeValue(forKey: pane)
                        next.pendingLaunches.removeValue(forKey: pane)
                        next.pendingInput.removeValue(forKey: pane)
                        next.view = updated
                        next.shouldExit = updated.tabs.isEmpty
                        presentationChanged = true
                    }
                }
            case .toggleZoom:
                if let updated = next.view.togglingZoom() {
                    next.view = updated
                    presentationChanged = true
                }
            case .enterResize:
                // The router already set `.resize`; refuse when no divider
                // exists rather than entering a mode that cannot act.
                if next.view.activeTab?.tree.splitIDs.isEmpty != false {
                    next.mode = .terminal
                    next.feedback = "Nothing to resize"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .resizeStep(let axis, let cells):
                if let tab = next.view.activeTab,
                   let tree = tab.tree.adjustingDivider(
                       near: tab.focusedPaneID, axis: axis, cells: cells, in: Self.viewport(next)
                   ),
                   let updated = next.view.settingTree(tree, for: tab.id),
                   PaneGeometry.solve(tree, in: Self.viewport(next)) != nil {
                    next.view = updated
                    presentationChanged = true
                } else {
                    next.feedback = "At minimum size"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .enterScroll:
                if case .scroll(let pane) = next.mode, next.view.panes[pane]?.binding != nil {
                    next.scrollGenerations[pane] = next.bindingKey(for: pane)?.generation ?? 0
                    if next.scrollAnchors[pane] == nil { next.scrollAnchors[pane] = 0 }
                } else {
                    next.mode = .terminal
                    next.feedback = "Nothing to scroll"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .scrollDelta(let lines):
                if case .scroll(let pane) = next.mode {
                    let step = abs(lines) >= CommandPrefix.scrollPageLines
                        ? (lines >= 0 ? Self.pageHeight(for: pane, in: next) : -Self.pageHeight(for: pane, in: next))
                        : lines
                    next.scrollAnchors[pane] = min(
                        Self.scrollTopSentinel, max(0, (next.scrollAnchors[pane] ?? 0) + step)
                    )
                    presentationChanged = true
                }
            case .scrollTop:
                if case .scroll(let pane) = next.mode {
                    // The sentinel means oldest retained; views clamp to the
                    // emulator's real history depth.
                    next.scrollAnchors[pane] = Self.scrollTopSentinel
                    presentationChanged = true
                }
            case .scrollBottom:
                if case .scroll(let pane) = next.mode {
                    next.scrollAnchors[pane] = 0
                    presentationChanged = true
                }
            case .exitScroll:
                if case .scroll(let pane) = previousMode {
                    next.scrollAnchors[pane] = 0
                    next.scrollGenerations.removeValue(forKey: pane)
                    presentationChanged = true
                }
            case .enterNavigator:
                next.navigatorItems = Self.navigatorItems(for: next)
                if next.navigatorItems.isEmpty {
                    next.mode = .terminal
                    next.feedback = "No tabs or runtimes"
                    next.feedbackTicks = 60
                } else {
                    next.mode = .navigator(index: 0)
                    effects = [.refreshInventory]
                }
                presentationChanged = true
            case .navigatorMove:
                // The router moved the index without knowing the row count.
                if navigatorIndexBefore != nil, case .navigator(let routed) = next.mode {
                    let fixed = min(max(0, next.navigatorItems.count - 1), max(0, routed))
                    next.mode = .navigator(index: fixed)
                    presentationChanged = true
                }
            case .navigatorActivate:
                if let index = navigatorIndexBefore,
                   next.navigatorItems.indices.contains(index) {
                    Self.activateNavigatorItem(
                        next.navigatorItems[index], in: &next,
                        effects: &effects, presentationChanged: &presentationChanged
                    )
                }
            case .enterConfirmCancel:
                // The router already set `.confirmCancel`; refuse when the
                // focused pane names no runtime to cancel.
                if next.activeBindingKey == nil {
                    next.mode = .terminal
                    next.feedback = "No runtime to cancel"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .confirmCancel:
                if let pane = confirmPaneBefore,
                   let binding = next.bindingKey(for: pane) {
                    effects = [.cancel(runtime: binding.runtime)]
                } else {
                    next.feedback = "No runtime to cancel"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .acquireInput:
                if let binding = next.activeBindingKey {
                    effects = [.acquire(binding: binding)]
                }
            case .releaseInput:
                if let binding = next.activeBindingKey {
                    effects = [.releaseInput(binding: binding)]
                }
            case .relaunchShell:
                if let launch = Self.relaunchFocusedShell(into: &next) {
                    effects = [launch]
                }
                presentationChanged = true
            case .launch(let choice):
                if Self.ensureLaunchPane(into: &next) {
                    presentationChanged = true
                }
                if let target = Self.target(next) {
                    effects = [.queueLaunch(target: target, choice: choice)]
                }
            case .submitRunCommand(let input):
                if Self.ensureLaunchPane(into: &next) {
                    presentationChanged = true
                }
                if let target = Self.target(next) {
                    effects = [.resolveRunCommand(target: target, input: input)]
                }
            case .invalidPrefix:
                next.feedback = "Unknown Ctrl-B command"
                next.feedbackTicks = 60
                presentationChanged = true
            case .detach, .help, .dismissOverlay, .finishResize, .exitNavigator, .dismissConfirm, nil:
                break
            }

        case .paste(let text):
            guard next.lifecycle == .connected, next.shouldExit == false else { break }
            switch next.mode {
            case .terminal:
                if let binding = Self.bindingForInput(next) {
                    effects = [.queuePaste(binding: binding, text: text)]
                }
            case .runCommand(let input, _):
                next.mode = .runCommand(input: input + text, error: nil)
                presentationChanged = true
            case .prefix, .help, .launcher, .resize, .scroll, .navigator, .confirmCancel:
                break
            }

        case .runCommandResolved(let target, let choice):
            guard next.lifecycle == .connected, Self.matches(target, in: next) else { break }
            // Success closes the overlay so the replacement is visible;
            // failures keep the editable input via .runCommandFailed.
            next.mode = .terminal
            effects = [.queueLaunch(target: target, choice: choice)]
            presentationChanged = true

        case .runCommandFailed(let target, let message):
            guard next.lifecycle == .connected, Self.matches(target, in: next),
                  case .runCommand(let input, _) = next.mode else { break }
            next.mode = .runCommand(input: input, error: message)
            next.updatePane(target.pane) {
                $0.lastOutcome = .launchFailed(message)
            }
            presentationChanged = true

        case .sendDue(let binding, let bytes):
            // Re-gate on the terminal worker: the lease may have moved since
            // the key was pressed or the emulator replied.
            guard next.lifecycle == .connected, next.shouldExit == false,
                  next.activeBindingKey == binding,
                  let terminal = next.terminal,
                  terminal.state.running else { break }
            guard next.leasedBindings.contains(binding) else {
                // The attach is still in flight; hold the keystrokes as
                // typeahead instead of dropping them on the floor.
                if next.queuePendingInput(bytes, for: binding) {
                    presentationChanged = true
                }
                break
            }
            effects = [.write(binding: binding, bytes: bytes)]

        case .emulatorSendDue(let binding, let bytes):
            guard next.lifecycle == .connected, next.shouldExit == false,
                  next.bindingKey(for: binding.pane) == binding,
                  next.terminals[binding.pane]?.state.running == true else { break }
            guard next.leasedBindings.contains(binding) else {
                if next.queuePendingInput(bytes, for: binding) {
                    presentationChanged = true
                }
                break
            }
            effects = [.write(binding: binding, bytes: bytes)]

        case .launchDue(let target, let choice):
            // Re-gate on the command worker: the request may have raced a
            // detach or another attach. A running terminal does not block a
            // replacement: the success path stashes it as pending and keeps
            // the old output until the new subscription attaches. The
            // serial command queue plus the pending marker collapse rapid
            // double submits; a residual same-instant duplicate stays
            // host-owned and discoverable, never attached twice.
            guard next.lifecycle == .connected, next.shouldExit == false,
                  Self.matches(target, in: next),
                  next.pendingLaunches[target.pane] == nil else { break }
            let size = Self.launchSize(for: target.pane, in: next)
            effects = [.launchQuery(target: target, choice: choice, rows: size.rows, columns: size.columns)]

        case .launchQuerySucceeded(let target, let choice, let runtime, let rows, let columns):
            // A launch that races UI detach belongs to the workspace now.
            // Keep it alive so the next TUI invocation can rediscover it.
            guard next.lifecycle == .connected, next.shouldExit == false,
                  Self.matches(target, in: next) else { break }
            // A completed launch belongs to the host even if this view
            // changed while the RPC was in flight. Stale generations are
            // dropped by matches() above; a success for a live pane is an
            // intentional replacement and flows into the pending branch
            // below, which keeps the old output until the new attach lands.
            guard next.paneID(for: runtime.id) == nil else { break }
            let candidate = Self.attached(runtime: runtime, title: choice.title, rows: rows, columns: columns)
            let generation = (next.view.panes[target.pane]?.binding?.generation ?? 0) &+ 1
            let binding = PaneBindingKey(pane: target.pane, runtime: runtime.id, generation: generation)
            if next.terminals[target.pane] != nil {
                // Keep the old emulator and output until the replacement
                // subscription succeeds. A failed attach remains editable.
                next.pendingLaunches[target.pane] = .init(binding: binding, terminal: candidate)
            } else {
                next.assignTerminal(candidate, to: target.pane)
                effects.append(.createEmulator(binding: binding, rows: rows, columns: columns))
            }
            next.updatePane(target.pane) { $0.lifecycle = .attaching }
            if next.activePaneID == target.pane { next.mode = .terminal }
            presentationChanged = true
            effects.append(.attach(binding: binding, context: .launch))

        case .launchQueryFailed(let target, let choice, let error):
            guard next.lifecycle == .connected, Self.matches(target, in: next) else { break }
            let message = Self.launchFailureMessage(error, profileID: choice.resourceProfileID)
            next.updatePane(target.pane) {
                $0.lifecycle = .launchFailed
                $0.lastOutcome = .launchFailed(message)
            }
            // The denial renders in the footer: a bare "launch failed"
            // in pane chrome names nothing. The profile case keeps its
            // fix-oriented text; every other failure shows its message.
            if error == .resourceProfileUnavailable {
                next.feedback = "Unknown id, wrong project, or changed policy — pick again"
            } else {
                next.feedback = message
            }
            next.feedbackTicks = 60
            if next.activePaneID == target.pane {
                if case .runCommand(let input, _) = next.mode {
                    next.mode = .runCommand(input: input, error: message)
                } else {
                    next.mode = .launcher
                }
            }
            presentationChanged = true

        case .inventoryRefreshed(let terminals):
            guard next.lifecycle == .connected else { break }
            next.knownRuntimes = terminals.sorted { $0.id.uuidString < $1.id.uuidString }
            if case .navigator(let index) = next.mode {
                let selected = next.navigatorItems.indices.contains(index)
                    ? next.navigatorItems[index] : nil
                next.navigatorItems = Self.navigatorItems(for: next)
                if let selected, let preserved = next.navigatorItems.firstIndex(of: selected) {
                    next.mode = .navigator(index: preserved)
                } else {
                    next.mode = .navigator(index: min(index, max(0, next.navigatorItems.count - 1)))
                }
                presentationChanged = true
            }

        case .hostEvents(let events):
            guard next.lifecycle == .connected else { break }
            for event in events {
                Self.applyHostEvent(event, to: &next, effects: &effects, presentationChanged: &presentationChanged)
            }

        case .emulatorResponded(let binding, let responses):
            guard next.lifecycle == .connected, responses.isEmpty == false else { break }
            guard next.leasedBindings.contains(binding), next.bindingKey(for: binding.pane) == binding,
                  let terminal = next.terminals[binding.pane],
                  terminal.state.lease == .owned else { break }
            effects = responses.map { response in
                next.activeBindingKey == binding
                    ? .queueSend(binding: binding, bytes: response)
                    : .queueEmulatorResponse(binding: binding, bytes: response)
            }

        case .sizeNoted(let rows, let columns, let now):
            // Called from the render pass: records geometry only, never an RPC.
            guard next.terminal != nil, next.lifecycle == .connected else { break }
            next.terminal?.resize.record(rows: rows, columns: columns, now: now)
            next.viewSize = .init(rows: rows + 2, columns: columns + 2)

        case .paneSizeNoted(let pane, let rows, let columns, let now):
            guard next.lifecycle == .connected, var terminal = next.terminals[pane] else { break }
            terminal.resize.record(rows: rows, columns: columns, now: now)
            next.terminals[pane] = terminal

        case .viewportNoted(let rows, let columns):
            next.viewSize = .init(rows: rows, columns: columns)

        case .notice(let message):
            next.feedback = message
            next.feedbackTicks = 180
            presentationChanged = true

        case .tick(let now):
            guard next.lifecycle != .detached else { break }
            if next.feedbackTicks > 0 {
                next.feedbackTicks -= 1
                if next.feedbackTicks == 0 {
                    next.feedback = nil
                    presentationChanged = true
                }
            }
            if next.lifecycle == .disconnected {
                Self.tickReconnect(now: now, to: &next, effects: &effects, presentationChanged: &presentationChanged)
                break
            }
            guard next.lifecycle == .connected else { break }
            let visible = next.view.activeTab.map { tab in
                tab.zoomedPaneID.map { [$0] } ?? tab.tree.leafIDs
            } ?? []
            for pane in visible {
                guard var terminal = next.terminals[pane],
                      // Ownership validation runs before the coalescer: an
                      // observer must not promote a size it cannot send, and
                      // its emulator keeps the runtime's actual dimensions
                      // until this client holds the lease.
                      terminal.state.lease == .owned,
                      let size = terminal.resize.flush(now: now),
                      let binding = next.bindingKey(for: pane) else { continue }
                next.terminals[pane] = terminal
                presentationChanged = true
                effects.append(.resizeEmulator(binding: binding, rows: size.rows, columns: size.columns))
                effects.append(.resize(binding: binding, rows: size.rows, columns: size.columns))
            }
            for pane in next.retryAcquirePanes {
                guard next.terminals[pane]?.state.lease == .readOnly,
                      let binding = next.bindingKey(for: pane) else { continue }
                effects.append(.acquire(binding: binding))
            }
            next.retryAcquirePanes.removeAll()
            for pane in next.retrySubscribePanes {
                guard let binding = next.bindingKey(for: pane),
                      next.terminals[pane]?.state.running == true,
                      next.terminals[pane]?.state.subscribed == false else { continue }
                effects.append(.attach(binding: binding, context: .resubscribeRetry))
            }
            next.retrySubscribePanes.removeAll()
            let probeDue: Bool
            if let lastProbe = next.lastSubscriptionProbeAt {
                probeDue = now.timeIntervalSince(lastProbe) >= WorkspaceTUIState.subscriptionProbeInterval
            } else {
                probeDue = true
            }
            if probeDue {
                next.lastSubscriptionProbeAt = now
                for paneID in next.view.panes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                    guard let binding = next.bindingKey(for: paneID),
                          next.terminals[paneID]?.state.running == true,
                          next.terminals[paneID]?.state.subscribed == true else { continue }
                    effects.append(.observe(binding: binding, context: .probe))
                }
            }

        case .reconnectFailed(let error):
            guard next.lifecycle == .disconnected else { break }
            next.reconnectInflight = false
            if error == .incompatibleHost {
                next.reconnectFiresAt = nil
                next.feedback = "Incompatible workspace host — close the workspace and retry"
                next.feedbackTicks = 3600
                presentationChanged = true
            } else if next.reconnectAttempt >= Self.maxReconnectAttempts {
                next.reconnectFiresAt = nil
                next.feedback = "Workspace unreachable — output preserved"
                next.feedbackTicks = 3600
                presentationChanged = true
            }
            // Otherwise the next tick schedules the following attempt.

        case .reconnectSucceeded(let terminals):
            guard next.lifecycle == .disconnected else { break }
            next.lifecycle = .connected
            next.reconnectAttempt = 0
            next.reconnectInflight = false
            next.reconnectFiresAt = nil
            next.knownRuntimes = terminals.sorted { $0.id.uuidString < $1.id.uuidString }
            next.feedback = "Reconnected"
            next.feedbackTicks = 60
            let available = Set(terminals.map(\.id))
            for paneID in next.view.panes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard let binding = next.bindingKey(for: paneID) else {
                    // An ambiguous launch never retries blindly: the pane
                    // returns to empty and any orphaned runtime stays
                    // discoverable through the refreshed inventory.
                    if next.view.panes[paneID]?.lifecycle == .launching {
                        next.updatePane(paneID) { $0.lifecycle = .empty }
                    }
                    continue
                }
                guard available.contains(binding.runtime) else {
                    next.updatePane(paneID) { $0.lifecycle = .missing }
                    continue
                }
                next.updatePane(paneID) { $0.lifecycle = .attaching }
                if next.preDisconnectLeases.contains(where: { $0.pane == paneID && $0.runtime == binding.runtime }) {
                    effects.append(.attach(binding: binding, context: .reconnect))
                } else {
                    effects.append(.observe(binding: binding, context: .reconnect))
                }
            }
            next.preDisconnectLeases.removeAll()
            effects.append(.restartEvents)
            presentationChanged = true

        case .hostDisconnected:
            // A disconnect that races detach must not resurrect the lease:
            // detached already released it and reported shouldExit.
            guard next.lifecycle != .detached else { break }
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
            if next.lifecycle == .connected {
                next.lifecycle = .disconnected
            }

        case .writeCompleted(let binding, let bytes, let outcome):
            // The terminal worker drains in-flight writes after detach; their
            // completions reduce here and must leave detached state alone.
            guard next.lifecycle != .detached,
                  next.bindingKey(for: binding.pane) == binding else { break }
            switch outcome {
            case .busy:
                presentationChanged = presentationChanged || next.terminals[binding.pane]?.state.lease != .readOnly
                next.terminals[binding.pane]?.state.lease = .readOnly
                next.leasedBindings.remove(binding)
                // The bytes never reached the runtime. Hold them as
                // typeahead (bounded) instead of dropping the keystroke:
                // the next grant flushes them, so input across a wedge
                // (overflow drop, lost lease race) is delayed, not lost.
                if next.queuePendingInput(bytes, for: binding) {
                    presentationChanged = true
                }
                // A refused write on a subscribed pane may mean the host
                // silently dropped the subscription (overflow) rather than
                // contention. One acquire distinguishes: unavailable
                // resubscribes, busy stays quiet. Contended observers never
                // reach here: without a lease their input queues as
                // typeahead instead of sending.
                if next.lifecycle == .connected,
                   next.terminals[binding.pane]?.state.running == true,
                   next.terminals[binding.pane]?.state.subscribed == true {
                    next.retryAcquirePanes.insert(binding.pane)
                }
            case .disconnected:
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            case .ok:
                break
            case .unavailable:
                // The runtime is gone; in-flight bytes died with it. The
                // pane exit covers that, so feedback only fires when the
                // pane still claims running (a genuinely surprising loss).
                if next.terminals[binding.pane]?.state.running == true {
                    next.feedback = "Terminal unavailable; input dropped"
                    next.feedbackTicks = 60
                    presentationChanged = true
                }
            case .rejected:
                if bytes.count > TerminalInputChunks.maximumTotalBytes {
                    next.feedback = "Input exceeds 1 MiB; rejected"
                } else {
                    next.feedback = "Write rejected; input dropped"
                }
                next.feedbackTicks = 60
                presentationChanged = true
            }

        case .acquireCompleted(let binding, let outcome):
            switch outcome {
            case .ok:
                // Release-after-acquire: a success that arrives after the
                // terminal moved on (or detached) must release the orphaned
                // lease instead of claiming it.
                let stillAvailable = next.lifecycle == .connected
                    && next.bindingKey(for: binding.pane) == binding
                    && next.terminals[binding.pane]?.state.running == true
                if stillAvailable {
                    if next.terminals[binding.pane]?.state.lease != .owned {
                        presentationChanged = true
                    }
                    next.terminals[binding.pane]?.state.lease = .owned
                    next.leasedBindings.insert(binding)
                    if let bytes = next.takePendingInput(for: binding) {
                        effects.append(.write(binding: binding, bytes: bytes))
                    }
                } else if next.lifecycle != .connected
                    || next.leasedBindings.contains(where: { $0.runtime == binding.runtime }) == false {
                    effects = [.release(runtime: binding.runtime)]
                }
            case .busy:
                guard next.lifecycle != .detached else { break }
                if next.bindingKey(for: binding.pane) == binding {
                    if next.terminals[binding.pane]?.state.lease != .readOnly {
                        presentationChanged = true
                    }
                    next.terminals[binding.pane]?.state.lease = .readOnly
                }
            case .unavailable, .rejected:
                guard next.lifecycle != .detached else { break }
                guard next.bindingKey(for: binding.pane) == binding else { break }
                if next.terminals[binding.pane]?.state.lease != .readOnly {
                    presentationChanged = true
                }
                next.terminals[binding.pane]?.state.lease = .readOnly
                // Acquire fails unavailable only when the host has no
                // subscription for this client (a silent overflow drop) or
                // the runtime is gone. A pane that believes it is subscribed
                // re-attaches; behind a gone runtime the attach outcome (or
                // its exited notice) converges instead of looping.
                if next.lifecycle == .connected,
                   next.terminals[binding.pane]?.state.running == true,
                   next.terminals[binding.pane]?.state.subscribed == true {
                    next.terminals[binding.pane]?.state.subscribed = false
                    next.retrySubscribePanes.remove(binding.pane)
                    effects.append(.attach(binding: binding, context: .resubscribe))
                    presentationChanged = true
                }
            case .disconnected:
                guard next.lifecycle != .detached,
                      next.bindingKey(for: binding.pane) == binding else { break }
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            }

        case .releaseInputCompleted(let binding, let outcome):
            guard next.lifecycle != .detached,
                  next.bindingKey(for: binding.pane) == binding else { break }
            switch outcome {
            case .disconnected:
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            case .ok, .busy, .unavailable, .rejected:
                // The host is the source of truth; any definitive reply
                // drops the local claim. Later `.inputOwner` events re-sync.
                presentationChanged = presentationChanged
                    || next.terminals[binding.pane]?.state.lease != .readOnly
                next.terminals[binding.pane]?.state.lease = .readOnly
                next.leasedBindings.remove(binding)
            }

        case .resizeCompleted(let binding, let rows, let columns, let outcome, let now):
            // As with writes: a resize that races detach reduces after the
            // lifecycle committed and must not touch detached state.
            guard next.lifecycle != .detached,
                  next.bindingKey(for: binding.pane) == binding else { break }
            switch outcome {
            case .busy:
                // The host rejected the resize: another client holds input.
                // Downgrade like a contended write, and un-apply the failed
                // size so a later tick retries it after the lease returns.
                presentationChanged = presentationChanged
                    || next.terminals[binding.pane]?.state.lease != .readOnly
                next.terminals[binding.pane]?.state.lease = .readOnly
                next.leasedBindings.remove(binding)
                next.terminals[binding.pane]?.resize.nack(rows: rows, columns: columns, now: now)
            case .disconnected:
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            case .unavailable:
                Self.applyRuntimeExited(runtime: binding.runtime, to: &next, presentationChanged: &presentationChanged)
            case .ok, .rejected:
                // A rejected resize carries an invalid request, never a lost
                // lease; retrying it would loop. It stays counted as sent.
                break
            }

        case .attachCompleted(let binding, let context, let outcome):
            if context == .launch,
               let pending = next.pendingLaunches[binding.pane], pending.binding == binding {
                next.pendingLaunches.removeValue(forKey: binding.pane)
                switch outcome {
                case .owned, .readOnly:
                    let previous = next.bindingKey(for: binding.pane)
                    let wasSubscribed = next.terminals[binding.pane]?.state.subscribed == true
                    next.assignTerminal(pending.terminal, to: binding.pane)
                    next.terminals[binding.pane]?.state.subscribed = true
                    next.terminals[binding.pane]?.state.lease = outcome == .owned ? .owned : .readOnly
                    next.updatePane(binding.pane) { $0.lifecycle = .running; $0.lastOutcome = nil }
                    if outcome == .owned { next.leasedBindings.insert(binding) }
                    if let previous {
                        if wasSubscribed || next.leasedBindings.contains(previous) {
                            effects.append(.release(runtime: previous.runtime))
                        }
                        effects.append(.dropEmulator(binding: previous))
                        next.leasedBindings.remove(previous)
                    }
                    let size = pending.terminal.resize.effectiveSize
                        ?? (rows: next.initialRows, columns: next.initialColumns)
                    effects.append(.createEmulator(
                        binding: binding, rows: size.rows, columns: size.columns
                    ))
                case .unavailable, .disconnected:
                    next.updatePane(binding.pane) {
                        $0.lifecycle = .launchFailed
                        $0.lastOutcome = .launchFailed("Terminal attach failed")
                    }
                    if outcome == .disconnected {
                        Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                        next.lifecycle = .disconnected
                    }
                }
                presentationChanged = true
                break
            }
            switch outcome {
            case .owned:
                // Release-after-acquire: a grant that arrives after the
                // terminal moved on (or detached) must release the orphaned
                // lease instead of claiming it.
                let stillAvailable = next.lifecycle == .connected
                    && next.bindingKey(for: binding.pane) == binding
                    && next.terminals[binding.pane]?.state.running == true
                if stillAvailable {
                    if next.terminals[binding.pane]?.state.lease != .owned {
                        presentationChanged = true
                    }
                    next.terminals[binding.pane]?.state.subscribed = true
                    next.terminals[binding.pane]?.state.lease = .owned
                    if context == .resubscribe || context == .resubscribeRetry {
                        next.terminals[binding.pane]?.state.overflowed = false
                        next.retrySubscribePanes.remove(binding.pane)
                        presentationChanged = true
                    }
                    next.updatePane(binding.pane) { $0.lifecycle = .running }
                    next.leasedBindings.insert(binding)
                    if let bytes = next.takePendingInput(for: binding) {
                        effects.append(.write(binding: binding, bytes: bytes))
                    }
                } else if next.leasedBindings.contains(where: { $0.runtime == binding.runtime }) == false {
                    effects = [.release(runtime: binding.runtime)]
                }
            case .readOnly:
                // A contended attach still subscribes; the lease stays
                // read-only until the host reports it free. Stale grants
                // (or detached ones) claim nothing.
                guard next.lifecycle == .connected,
                      next.bindingKey(for: binding.pane) == binding else { break }
                if context == .probe {
                    // Probe success means the host had silently dropped us;
                    // the subscription is live again. Lease claimants keep
                    // their claim and reclaim on tick (confirming rather
                    // than flopping the lease); observers are already home.
                    if next.leasedBindings.contains(binding) {
                        next.retryAcquirePanes.insert(binding.pane)
                    }
                    presentationChanged = true
                    break
                }
                if next.terminals[binding.pane]?.state.lease != .readOnly {
                    presentationChanged = true
                }
                next.terminals[binding.pane]?.state.subscribed = true
                next.terminals[binding.pane]?.state.lease = .readOnly
                if context == .resubscribe || context == .resubscribeRetry {
                    next.terminals[binding.pane]?.state.overflowed = false
                    next.retrySubscribePanes.remove(binding.pane)
                    presentationChanged = true
                }
                next.updatePane(binding.pane) { $0.lifecycle = .running }
            case .unavailable, .disconnected:
                // Failure handling mutates the terminal (unavailable titles,
                // launcher fallback, emulator drops); detached state is final.
                guard next.lifecycle != .detached,
                      next.bindingKey(for: binding.pane) == binding else { break }
                if outcome == .disconnected {
                    Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                    if next.lifecycle == .connected {
                        next.lifecycle = .disconnected
                    }
                }
                switch context {
                case .connect:
                    if outcome == .unavailable {
                        if next.terminals[binding.pane]?.state.lease != .readOnly {
                            presentationChanged = true
                        }
                        next.terminals[binding.pane]?.state.subscribed = false
                        next.terminals[binding.pane]?.state.lease = .readOnly
                    }
                case .ensure:
                    next.terminals[binding.pane]?.state.title += " (unavailable)"
                    presentationChanged = presentationChanged || next.terminals[binding.pane]?.state.lease != .readOnly
                    next.terminals[binding.pane]?.state.lease = .readOnly
                    next.terminals[binding.pane]?.state.subscribed = false
                case .launch:
                    next.updatePane(binding.pane) {
                        $0.lifecycle = .launchFailed
                        $0.lastOutcome = .launchFailed("Terminal attach failed")
                    }
                    if next.activePaneID == binding.pane, next.lifecycle == .connected {
                        next.mode = .launcher
                    }
                    presentationChanged = true
                case .reconnect:
                    next.updatePane(binding.pane) { $0.lifecycle = .missing }
                    presentationChanged = true
                case .resubscribe:
                    // The drop races this RPC across connections; the tick
                    // retries until the subscribe lands. The lease is left
                    // alone: a stale owned claim renders behind the
                    // skipped-output indicator and self-heals on send, while
                    // read-only would spam acquires that fail closed without
                    // a subscription.
                    if outcome == .unavailable {
                        next.retrySubscribePanes.insert(binding.pane)
                        presentationChanged = true
                    }
                case .resubscribeRetry:
                    // One-shot spent. A repeat failure means the runtime is
                    // gone; staying quiet instead of RPC-spamming the tick.
                    break
                case .probe:
                    // Probe failure means the existing subscription is
                    // healthy (subscribe refused a duplicate). No-op.
                    break
                }
            }

        case .detachRequested:
            guard next.lifecycle != .detached else { break }
            next.lifecycle = .detached
            next.shouldExit = true
            presentationChanged = true
            // One release covers the lease and the subscription alike;
            // the usual case (leased and subscribed to one runtime)
            // emits a single effect.
            var releases = next.leasedBindings.map(\.runtime)
            for terminal in next.terminals.values where terminal.state.subscribed {
                if releases.contains(terminal.state.runtime) == false { releases.append(terminal.state.runtime) }
            }
            effects.append(contentsOf: releases.map(TUIRuntimeEffect.release))
            next.leasedBindings.removeAll()
            next.retryAcquirePanes.removeAll()
            next.retrySubscribePanes.removeAll()
            next.pendingInput.removeAll()
            for pane in next.terminals.keys {
                next.terminals[pane]?.state.lease = .released
                next.terminals[pane]?.state.subscribed = false
            }
            effects.append(.detach)
        }
        if presentationChanged {
            next.presentationRevision &+= 1
        }
        return WorkspaceTUITransition(state: next, effects: effects)
    }

    private static func applyHostEvent(
        _ event: WorkspaceTUIEvent,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch event {
        case .replayBegin(let runtime, let batch, let truncated, _):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane),
                  let terminal = next.terminals[pane] else { return }
            next.replayBatches[pane] = batch
            if truncated { next.recentOutputOnly.insert(pane) }
            else { next.recentOutputOnly.remove(pane) }
            let size = terminal.resize.effectiveSize
                ?? (rows: next.initialRows, columns: next.initialColumns)
            effects.append(.createEmulator(binding: binding, rows: size.rows, columns: size.columns))
            presentationChanged = true
        case .replayEnd(let runtime, let batch):
            guard let pane = next.paneID(for: runtime), next.replayBatches[pane] == batch else { return }
            next.replayBatches.removeValue(forKey: pane)
            presentationChanged = true
        case .bytes(let runtime, let data):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane) else { return }
            guard data.isEmpty == false else { return }
            effects.append(.feedEmulator(binding: binding, data: data))
            presentationChanged = true
        case .overflow(let runtime):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane),
                  next.terminals[pane]?.state.running == true else { return }
            if next.terminals[pane]?.state.overflowed != true {
                next.terminals[pane]?.state.overflowed = true
            }
            // The host dropped this subscription; without a resubscribe the
            // pane goes dark and input acquire fails closed. The overflow
            // notice is already on the wire, so the same client id may
            // subscribe again immediately; a cross-connection race lands in
            // the tick retry set through the failure branch below.
            next.terminals[pane]?.state.subscribed = false
            next.retrySubscribePanes.remove(pane)
            effects.append(.attach(binding: binding, context: .resubscribe))
            presentationChanged = true
        case .window(let runtime, let rows, let columns):
            // Actual PTY dimensions, published by the owner's resize. Only
            // observers apply them: the owner drives its emulator from its
            // own coalescer and must not have it rewritten underneath.
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane),
                  next.leasedBindings.contains(binding) == false,
                  next.terminals[pane]?.state.running == true else { return }
            effects.append(.resizeEmulator(binding: binding, rows: rows, columns: columns))
            presentationChanged = true
        case .exited(let runtime, let status):
            guard let pane = next.paneID(for: runtime) else { return }
            if next.terminals[pane]?.state.running != false || next.terminals[pane]?.state.exitStatus != status
                || next.terminals[pane]?.state.lease != .released {
                presentationChanged = true
            }
            next.terminals[pane]?.state.running = false
            next.terminals[pane]?.state.exitStatus = status
            next.terminals[pane]?.state.lease = .released
            next.updatePane(pane) { $0.lifecycle = .exited; $0.lastOutcome = .exited(status) }
            if let binding = next.bindingKey(for: pane) {
                next.leasedBindings.remove(binding)
            }
            // The final output stays on screen; the launcher offers a
            // replacement runtime and number keys select it directly.
            if next.activePaneID == pane, next.mode != .launcher {
                next.mode = .launcher
                presentationChanged = true
            }
        case .inputOwner(let runtime, let owned):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane) else { return }
            if owned {
                // The host broadcasts only that an owner exists, not which
                // client owns it. Only our successful acquire RPC grants
                // local write authority.
                if next.leasedBindings.contains(binding) == false {
                    presentationChanged = presentationChanged || next.terminals[pane]?.state.lease != .readOnly
                    next.terminals[pane]?.state.lease = .readOnly
                }
            } else {
                // Notifications do not carry a lease generation. A queued
                // release from an earlier epoch may arrive after a later
                // acquire succeeded, so the successful acquire is
                // authoritative while this client still claims ownership.
                guard next.leasedBindings.contains(binding) == false else { return }
                presentationChanged = presentationChanged || next.terminals[pane]?.state.lease != .readOnly
                next.terminals[pane]?.state.lease = .readOnly
                if next.terminals[pane]?.state.running == true {
                    next.retryAcquirePanes.insert(pane)
                }
            }
        }
    }

    private static func applyDisconnect(to next: inout WorkspaceTUIState, presentationChanged: inout Bool) {
        presentationChanged = presentationChanged
            || next.lifecycle == .connected
            || next.terminals.values.contains { $0.state.lease != .readOnly || $0.state.subscribed || $0.state.overflowed }
        // A second disconnect during reattach must not clobber the original
        // stash with an empty in-flight set.
        if next.leasedBindings.isEmpty == false {
            next.preDisconnectLeases = next.leasedBindings
        }
        next.leasedBindings.removeAll()
        next.retryAcquirePanes.removeAll()
        next.retrySubscribePanes.removeAll()
        for pane in next.terminals.keys {
            next.terminals[pane]?.state.lease = .readOnly
            next.terminals[pane]?.state.subscribed = false
            next.terminals[pane]?.state.overflowed = false
            next.updatePane(pane) { $0.lifecycle = .disconnected }
        }
    }

    private static func applyRuntimeExited(
        runtime: UUID,
        to next: inout WorkspaceTUIState,
        presentationChanged: inout Bool
    ) {
        guard let pane = next.paneID(for: runtime) else { return }
        var changed = next.terminals[pane]?.state.running != false || next.terminals[pane]?.state.exitStatus != nil
            || next.terminals[pane]?.state.lease != .released
        next.terminals[pane]?.state.running = false
        next.terminals[pane]?.state.exitStatus = nil
        next.terminals[pane]?.state.lease = .released
        next.updatePane(pane) { $0.lifecycle = .exited }
        if let binding = next.bindingKey(for: pane) {
            next.leasedBindings.remove(binding)
        }
        if next.activePaneID == pane, next.mode != .launcher {
            next.mode = .launcher
            changed = true
        }
        presentationChanged = presentationChanged || changed
    }

    private static func bindingForInput(_ state: WorkspaceTUIState) -> PaneBindingKey? {
        guard state.lifecycle == .connected, state.shouldExit == false,
              let terminal = state.terminal, terminal.state.running else { return nil }
        return state.activeBindingKey
    }

    /// Sentinel anchor meaning oldest retained output. Views clamp it to the
    /// emulator's real history depth.
    static let scrollTopSentinel = 10_000

    /// Bounded reconnect: twelve attempts over roughly a minute, then the
    /// view stays on its preserved output until the user retries or detaches.
    static let maxReconnectAttempts = 12

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(8.0, 0.25 * pow(2.0, Double(max(0, attempt))))
    }

    private static func tickReconnect(
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.reconnectInflight == false,
              next.reconnectAttempt < Self.maxReconnectAttempts else { return }
        if let firesAt = next.reconnectFiresAt {
            guard now >= firesAt else { return }
            next.reconnectFiresAt = nil
            next.reconnectInflight = true
            next.reconnectAttempt += 1
            next.feedback = "Reconnecting…"
            next.feedbackTicks = 60
            effects = [.reconnectQuery]
            presentationChanged = true
        } else {
            next.reconnectFiresAt = now.addingTimeInterval(
                Self.reconnectDelay(attempt: next.reconnectAttempt)
            )
        }
    }

    private static func scrollStale(_ pane: PaneID, in state: WorkspaceTUIState) -> Bool {
        guard state.view.panes[pane] != nil else { return true }
        guard let expected = state.scrollGenerations[pane] else { return false }
        return state.bindingKey(for: pane)?.generation != expected
    }

    private static func pageHeight(for pane: PaneID, in state: WorkspaceTUIState) -> Int {
        if let tab = state.view.activeTab, tab.tree.leafIDs.contains(pane),
           let geometry = PaneGeometry.solve(tab.tree, in: viewport(state)),
           let placement = geometry[pane] {
            return max(1, placement.content.height)
        }
        return CommandPrefix.scrollPageLines
    }

    private static func navigatorItems(for state: WorkspaceTUIState) -> [NavigatorItem] {
        var items: [NavigatorItem] = []
        if let pane = state.activePaneID,
           state.terminals[pane]?.state.running == true,
           let binding = state.bindingKey(for: pane) {
            items.append(state.leasedBindings.contains(binding) ? .releaseInput : .acquireInput)
        }
        for (index, tab) in state.view.tabs.enumerated() {
            items.append(.tab(id: tab.id, title: tab.userTitle ?? "tab \(index + 1)", index: index))
        }
        let placed = Set(state.view.panes.values.compactMap { $0.binding?.runtime.rawValue })
        for runtime in state.knownRuntimes where placed.contains(runtime.id) == false {
            items.append(.runtime(id: runtime.id, label: Self.navigatorLabel(for: runtime)))
        }
        return items
    }

    private static func navigatorLabel(for runtime: ListedRuntime) -> String {
        if let hook = runtime.hook, hook.isEmpty == false { return hook }
        return "runtime \(runtime.id.uuidString.prefix(8))"
    }

    private static func activateNavigatorItem(
        _ item: NavigatorItem,
        in next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch item {
        case .acquireInput:
            if let binding = next.activeBindingKey { effects.append(.acquire(binding: binding)) }
        case .releaseInput:
            if let binding = next.activeBindingKey { effects.append(.releaseInput(binding: binding)) }
        case .tab(let id, _, _):
            if let updated = next.view.activatingTab(id), updated != next.view {
                next.view = updated
                presentationChanged = true
            }
        case .runtime(let id, _):
            guard let pane = next.activePaneID else {
                next.feedback = "Open a tab first (Ctrl-B c)"
                next.feedbackTicks = 60
                presentationChanged = true
                return
            }
            guard next.terminals[pane]?.state.running != true,
                  let runtime = next.knownRuntimes.first(where: { $0.id == id }),
                  next.paneID(for: id) == nil else {
                next.feedback = "Runtime is no longer available"
                next.feedbackTicks = 60
                presentationChanged = true
                return
            }
            let previous = next.bindingKey(for: pane)
            let wasSubscribed = next.terminals[pane]?.state.subscribed == true
            let wasLeased = previous.map { next.leasedBindings.contains($0) } ?? false
            let rows = runtime.rows.map(Self.bound) ?? next.initialRows
            let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
            next.assignTerminal(Self.attached(
                runtime: runtime, title: runtime.hook ?? "runtime", rows: rows, columns: columns
            ), to: pane)
            if let binding = next.bindingKey(for: pane) {
                effects.append(.createEmulator(binding: binding, rows: rows, columns: columns))
                effects.append(.attach(binding: binding, context: .launch))
            }
            if let previous, previous.runtime != id, wasSubscribed || wasLeased {
                effects.append(.release(runtime: previous.runtime))
            }
            next.updatePane(pane) { $0.lifecycle = .attaching }
            presentationChanged = true
        }
    }

    /// Creates a tab for a launcher/run-command choice when the view is
    /// intentionally empty. Returns true when it changed the layout.
    private static func ensureLaunchPane(into next: inout WorkspaceTUIState) -> Bool {
        guard next.lifecycle == .connected, next.activePaneID == nil,
              let updated = next.view.addingTab() else { return false }
        next.view = updated
        if let pane = next.activePaneID {
            next.updatePane(pane) { $0.lifecycle = .launching }
        }
        return true
    }

    /// Enter on a dead pane starts a new default shell in place. Returns the
    /// launch effect, or nil when the pane is live, the host is unreachable,
    /// or no default shell is configured. Never reruns previous argv.
    private static func relaunchFocusedShell(into next: inout WorkspaceTUIState) -> TUIRuntimeEffect? {
        guard next.lifecycle == .connected,
              let pane = next.activePaneID,
              next.terminals[pane]?.state.running != true,
              let lifecycle = next.view.panes[pane]?.lifecycle,
              [.empty, .exited, .launchFailed].contains(lifecycle),
              let target = Self.target(next),
              let shell = Self.defaultShell(next) else { return nil }
        next.updatePane(pane) { $0.lifecycle = .launching }
        return .queueLaunch(target: target, choice: shell)
    }

    private static func target(_ state: WorkspaceTUIState) -> PrefixTarget? {
        state.activePaneID.map { PrefixTarget(pane: $0, generation: state.activeBindingKey?.generation) }
    }

    private static func matches(_ target: PrefixTarget, in state: WorkspaceTUIState) -> Bool {
        guard state.view.panes[target.pane] != nil else { return false }
        return state.bindingKey(for: target.pane)?.generation == target.generation
    }

    private static func viewport(_ state: WorkspaceTUIState) -> CellRect {
        let size = state.viewSize ?? .init(rows: state.initialRows + 2, columns: state.initialColumns + 2)
        return CellRect(x: 0, y: 0, width: max(1, size.columns), height: max(1, size.rows))
    }

    private static func defaultShell(_ state: WorkspaceTUIState) -> RuntimeLaunchChoice? {
        state.launcher.first { $0.id == state.defaultShellID }
            ?? state.launcher.first { $0.id == RuntimeLaunchChoice.shellID }
    }

    private static func launchSize(for pane: PaneID, in state: WorkspaceTUIState) -> WorkspaceTUIState.ViewSize {
        if let tab = state.view.activeTab, tab.tree.leafIDs.contains(pane),
           let geometry = PaneGeometry.solve(tab.tree, in: viewport(state)),
           let placement = geometry[pane] {
            return .init(rows: placement.content.height, columns: placement.content.width)
        }
        if let size = state.terminals[pane]?.resize.effectiveSize {
            return .init(rows: size.rows, columns: size.columns)
        }
        return .init(rows: state.initialRows, columns: state.initialColumns)
    }

    private static func launchFailureMessage(_ error: WorkspaceTUIError, profileID: String?) -> String {
        switch error {
        case .resourceProfileUnavailable:
            if let profileID { "Resource profile '\(profileID)' unavailable" }
            else { "Resource profile unavailable" }
        case .resourceStagingFailed(let detail):
            if let profileID { "Profile '\(profileID)' staging failed: \(detail) unusable" }
            else { "Staging failed: \(detail) unusable" }
        case .incompatibleHost: "Incompatible workspace host — close the workspace and retry"
        case .disconnected: "Workspace disconnected"
        case .busy: "Workspace busy"
        case .unavailable: "Runtime unavailable"
        case .rejected: "Launch rejected"
        }
    }

    private static func attached(
        runtime: ListedRuntime,
        title: String,
        rows: Int,
        columns: Int
    ) -> WorkspaceTUIState.AttachedTerminal {
        var resize = ResizeCoalescer()
        resize.recordLaunch(rows: rows, columns: columns)
        return WorkspaceTUIState.AttachedTerminal(
            state: WorkspaceTerminalState(
                runtime: runtime.id,
                title: title,
                running: runtime.running
            ),
            resize: resize
        )
    }

    private static func bound(_ value: Int) -> Int {
        min(512, max(1, value))
    }
}
