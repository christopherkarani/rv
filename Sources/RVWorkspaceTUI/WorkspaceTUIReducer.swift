import Foundation
import RVDomain

/// Identity of one bound pane: the pane, the runtime it shows, and the
/// binding generation. Always bound (no optional members): every RPC
/// effect and bound completion carries one.
///
/// Pane identity comes in three keys on purpose, one per role, because
/// their optionality differs in load-bearing ways (see `PaneIdentityTests`):
/// - `PaneBindingKey` (this type): a bound operation's exact target.
/// - `PrefixTarget`: a pre-binding intent (launch, run command). Its
///   generation is nil for unbound panes and matches unbound only, so
///   one type cannot serve both roles without admitting operations on
///   unbound panes or intents that name a runtime that does not exist yet.
/// - `RuntimeBinding`: the persisted reference, scoped by workspace.
///   Merging it into operational keys would drag workspace ids and
///   persistence defaults into every effect.
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
    /// One live runtime record per pane, replacing the old parallel
    /// per-pane maps. Invariant: every bound pane has a record (a bound
    /// pane with no record can only be a restored pane awaiting its
    /// first reconcile, covered by the nil branch of
    /// `derivedLifecycle`). Records without bindings are launch intents
    /// for fresh panes.
    var panes: [PaneID: PaneRuntime] = [:]
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
    /// Last inventoried host runtimes, sorted by id. References only.
    var knownRuntimes: [ListedRuntime] = []
    /// Rows built when the navigator opened, rebuilt on inventory refresh.
    var navigatorItems: [NavigatorItem] = []
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

    /// The terminal slot one pane's reads and writes touch. See
    /// `PaneRuntime.terminal` for the per-phase mapping.
    func terminal(for paneID: PaneID) -> AttachedTerminal? {
        panes[paneID]?.terminal
    }

    /// Reads, mutates, and routes one pane's terminal slot back into its
    /// phase. Nil-tolerant like the old map subscript: panes without a
    /// slot are left alone. Stamps the pane's derived lifecycle so the
    /// stored value never drifts from the phase, even for direct
    /// (test-side) construction.
    mutating func updateTerminal(_ paneID: PaneID, _ update: (inout AttachedTerminal) -> Void) {
        guard var slot = panes[paneID]?.terminal else { return }
        update(&slot)
        setTerminal(slot, for: paneID)
        syncPaneLifecycle(paneID)
    }

    /// Routes a whole terminal value back into its phase's slot. Panes
    /// without a record, or a record without a slot, are left alone.
    mutating func setTerminal(_ terminal: AttachedTerminal, for paneID: PaneID) {
        switch panes[paneID]?.phase {
        case .launching(var detail):
            if detail.previous != nil {
                detail.previous = terminal
            } else if detail.candidate != nil {
                detail.candidate?.terminal = terminal
            } else {
                return
            }
            panes[paneID]?.phase = .launching(detail)
        case .attached:
            panes[paneID]?.phase = .attached(terminal)
        case .failed(.some):
            panes[paneID]?.phase = .failed(stale: terminal)
        case .missing(.some):
            panes[paneID]?.phase = .missing(stale: terminal)
        case .failed(nil), .missing(nil):
            return
        case .disconnected:
            panes[paneID]?.phase = .disconnected(stale: terminal)
        case nil:
            return
        }
    }

    mutating func assignTerminal(_ value: AttachedTerminal?, to paneID: PaneID) {
        guard let oldPane = view.panes[paneID] else { return }
        if let oldBinding = oldPane.binding, value?.state.runtime != oldBinding.runtime.rawValue {
            dropLeaseClaim(PaneBindingKey(
                pane: paneID, runtime: oldBinding.runtime.rawValue, generation: oldBinding.generation
            ))
        }
        let binding: RuntimeBinding?
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
            outcome = value.state.exitStatus.map(WorkspacePaneOutcome.exited) ?? oldPane.lastOutcome
            var runtime = panes[paneID] ?? PaneRuntime(phase: .attached(value))
            runtime.phase = .attached(value)
            runtime.input = nil
            panes[paneID] = runtime
        } else {
            binding = nil
            outcome = oldPane.lastOutcome
            // Only the init seed passes nil, and it skips nil seeds, so
            // this removes the whole runtime record. No production or
            // test path assigns nil to a live pane.
            panes[paneID] = nil
        }
        view = view.updatingPane(WorkspacePane(
            id: paneID, userTitle: oldPane.userTitle, binding: binding,
            lifecycle: oldPane.lifecycle, lastOutcome: outcome
        )) ?? view
        syncPaneLifecycle(paneID)
    }

    /// Records a launch failure, preserving stale output and every
    /// non-phase field (claim, typeahead, scroll, retries). A pane with
    /// an attach in flight keeps its candidate: the failure is for a
    /// raced query, and the in-flight attach still decides the pane.
    mutating func failLaunch(for paneID: PaneID, message: String) {
        switch panes[paneID]?.phase {
        case .launching(let detail) where detail.candidate != nil:
            break
        case .launching(let detail):
            if let previous = detail.previous {
                // A relaunch keeps its previous output as the stale terminal.
                panes[paneID]?.phase = .failed(stale: previous)
            } else if view.panes[paneID]?.binding != nil {
                // A bound pane with no slot (restored runtime, or Enter
                // retrying a slot-less failure) must stay .failed. Dropping
                // the record would derive .missing and refuse another Enter.
                // Scroll, claims, and the rest of the record stay.
                panes[paneID]?.phase = .failed(stale: nil)
            } else {
                // A fresh unbound intent holds nothing else, so dropping
                // the record loses nothing. lastOutcome still derives
                // .launchFailed.
                panes[paneID] = nil
            }
        case .attached(let slot), .failed(let slot?), .missing(let slot?), .disconnected(let slot):
            panes[paneID]?.phase = .failed(stale: slot)
        case .failed(nil), .missing(nil):
            panes[paneID]?.phase = .failed(stale: nil)
        case nil:
            break
        }
        updatePane(paneID) { $0.lastOutcome = .launchFailed(message) }
    }

    /// Drops the desired lease claim for exactly this binding. Anything
    /// else stays put.
    mutating func dropLeaseClaim(_ binding: PaneBindingKey) {
        if panes[binding.pane]?.leaseClaim == binding {
            panes[binding.pane]?.leaseClaim = nil
        }
    }

    /// Marks one pane's terminal exited. Resting phases land on the
    /// exited terminal; a pane with an attach in flight keeps its
    /// phase, and the in-flight attach still decides it.
    mutating func markExited(_ paneID: PaneID, status: Int32?) {
        updateTerminal(paneID) {
            $0.state.running = false
            $0.state.exitStatus = status
            $0.state.lease = .released
        }
        switch panes[paneID]?.phase {
        case .launching:
            break
        case .failed, .missing, .disconnected, .attached, nil:
            if let slot = terminal(for: paneID) {
                panes[paneID]?.phase = .attached(slot)
            }
        }
    }

    /// Lands a successful attach on the terminal slot: the pane becomes
    /// attached unless the success is for an older binding while a
    /// newer candidate is still in flight (a probe or resubscribe racing
    /// a replacement), in which case the candidate survives and the pane
    /// keeps reading attaching until that attach decides it.
    mutating func landAttach(for binding: PaneBindingKey) {
        if case .launching(let detail)? = panes[binding.pane]?.phase,
           let candidate = detail.candidate, candidate.binding != binding {
            return
        }
        if let slot = panes[binding.pane]?.terminal {
            panes[binding.pane]?.phase = .attached(slot)
        }
    }

    mutating func updatePane(_ paneID: PaneID, _ update: (inout WorkspacePane) -> Void) {
        guard var pane = view.panes[paneID] else { return }
        update(&pane)
        view = view.updatingPane(pane) ?? view
    }

    /// Derives one pane's lifecycle from its runtime phase. This is the
    /// only function that maps phases to lifecycles: production code
    /// never assigns `WorkspacePane.lifecycle` directly (the layout
    /// store's restored views predate any phase and are reconciled on
    /// connect). The nil branch covers unbound panes (empty, or failed
    /// when a failure outcome stands) plus bound panes awaiting their
    /// first reconcile: restored panes before connect, and panes whose
    /// saved runtime is gone.
    func derivedLifecycle(for paneID: PaneID) -> WorkspacePaneLifecycle {
        switch panes[paneID]?.phase {
        case .launching(let detail):
            return detail.candidate == nil ? .launching : .attaching
        case .attached(let terminal):
            return terminal.state.running ? .running : .exited
        case .failed:
            return .launchFailed
        case .missing:
            return .missing
        case .disconnected:
            return .disconnected
        case nil:
            guard let pane = view.panes[paneID] else { return .empty }
            if pane.binding == nil {
                if case .launchFailed = pane.lastOutcome { return .launchFailed }
                return .empty
            }
            return lifecycle == .connected ? .missing : .disconnected
        }
    }

    /// Stamps one pane's stored lifecycle from its phase. Idempotent.
    mutating func syncPaneLifecycle(_ paneID: PaneID) {
        let derived = derivedLifecycle(for: paneID)
        if view.panes[paneID]?.lifecycle != derived {
            updatePane(paneID) { $0.lifecycle = derived }
        }
    }

    /// Stamps every pane's stored lifecycle from its phase. Runs at the
    /// end of every reduce, so at rest a lifecycle can never contradict
    /// its phase. Never touches the presentation revision: each branch
    /// keeps its own revision accounting.
    mutating func syncPaneLifecycles() {
        for paneID in view.panes.keys {
            syncPaneLifecycle(paneID)
        }
    }

    /// Holds typeahead for a lease that has not landed yet. Bytes past one
    /// host write are dropped while the lease is out; the pane keeps
    /// responding instead of wedging on an unbounded queue. Returns true
    /// when bytes were dropped so the caller can surface the loss: a
    /// truncated paste is data loss, never a quiet cap.
    mutating func queuePendingInput(_ bytes: Data, for binding: PaneBindingKey) -> Bool {
        guard bytes.isEmpty == false else { return false }
        var current = panes[binding.pane]?.input.flatMap { $0.binding == binding ? $0.bytes : nil } ?? Data()
        let room = Self.maximumPendingInputBytes - min(current.count, Self.maximumPendingInputBytes)
        let admitted = bytes.prefix(room)
        current.append(admitted)
        panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))].input = PendingPaneInput(
            binding: binding, bytes: current
        )
        let truncated = admitted.count < bytes.count
        if truncated {
            feedback = "Typeahead full; dropped \(bytes.count - admitted.count) bytes"
            feedbackTicks = 60
        }
        return truncated
    }

    /// Sets one pane's scroll anchor, preserving the generation scroll
    /// mode opened under (re-pinned from the live binding when absent,
    /// which only crafted events without scroll mode can observe).
    /// A pane with no record is left alone. Inserting `.missing` would
    /// derive missing before connect, while a nil record still reads
    /// disconnected, and the anchor reads as 0 either way.
    mutating func setScrollAnchor(_ anchor: Int, for paneID: PaneID) {
        guard panes[paneID] != nil else { return }
        let generation = panes[paneID]?.scroll?.generation
            ?? bindingKey(for: paneID)?.generation ?? 0
        panes[paneID]?.scroll = ScrollPosition(anchor: anchor, generation: generation)
    }

    /// Takes bytes queued for exactly this binding. Anything else stays put.
    mutating func takePendingInput(for binding: PaneBindingKey) -> Data? {
        guard panes[binding.pane]?.input?.binding == binding,
              let bytes = panes[binding.pane]?.input?.bytes, bytes.isEmpty == false else { return nil }
        panes[binding.pane]?.input = nil
        return bytes
    }

    /// Compatibility projection for the first visible pane. WorkspaceView and
    /// the pane-keyed runtime records are the only stored presentation state.
    var terminal: AttachedTerminal? {
        get {
            guard let activePaneID else { return nil }
            return panes[activePaneID]?.terminal
        }
        set {
            guard let activePaneID else { return }
            assignTerminal(newValue, to: activePaneID)
        }
    }

    var leasedRuntime: UUID? {
        get { activeBindingKey.flatMap { panes[$0.pane]?.leaseClaim == $0 ? $0.runtime : nil } }
        set {
            guard let key = activeBindingKey else { return }
            if newValue == key.runtime {
                panes[key.pane, default: PaneRuntime(phase: .missing(stale: nil))].leaseClaim = key
            } else {
                dropLeaseClaim(key)
            }
        }
    }

    var retryAcquire: Bool {
        get { activePaneID.flatMap { panes[$0]?.retries.contains(.acquire) } ?? false }
        set {
            guard let pane = activePaneID else { return }
            if newValue {
                // A retry without a runtime record is unobservable (the
                // tick skips panes without a readable lease), so there is
                // nothing to arm.
                panes[pane]?.retries.insert(.acquire)
            } else {
                panes[pane]?.retries.remove(.acquire)
            }
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
        self.panes = [:]
        // A retry for the fresh pane is unobservable (no binding, no
        // lease to read), so the seed arms nothing. The model always
        // passes false; the projection covers live panes.
        _ = retryAcquire
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
            reduceConnectQuery(
                described: described, runtimes: runtimes,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .connectQueryFailed:
            reduceConnectQueryFailed(to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .launchDefaultRequested:
            reduceLaunchDefaultRequested(to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .ensureSucceeded(let target, let runtime, let shell):
            reduceEnsureSucceeded(
                target: target, runtime: runtime, shell: shell,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .ensureFailed(let target, let error, let profileID):
            reduceEnsureFailed(
                target: target, error: error, profileID: profileID,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .key(let key):
            reduceKey(key, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .paste(let text):
            reducePaste(text, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .runCommandResolved(let target, let choice):
            reduceRunCommandResolved(
                target: target, choice: choice,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .runCommandFailed(let target, let message):
            reduceRunCommandFailed(
                target: target, message: message,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .sendDue(let binding, let bytes):
            reduceSendDue(
                binding: binding, bytes: bytes,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .emulatorSendDue(let binding, let bytes):
            reduceEmulatorSendDue(
                binding: binding, bytes: bytes,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .launchDue(let target, let choice):
            reduceLaunchDue(
                target: target, choice: choice,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .launchQuerySucceeded(let target, let choice, let runtime, let rows, let columns):
            reduceLaunchQuerySucceeded(
                target: target, choice: choice, runtime: runtime, rows: rows, columns: columns,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .launchQueryFailed(let target, let choice, let error):
            reduceLaunchQueryFailed(
                target: target, choice: choice, error: error,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .inventoryRefreshed(let terminals):
            reduceInventoryRefreshed(
                terminals: terminals,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .hostEvents(let events):
            reduceHostEvents(events, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .emulatorResponded(let binding, let responses):
            reduceEmulatorResponded(
                binding: binding, responses: responses,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .sizeNoted(let rows, let columns, let now):
            reduceSizeNoted(
                rows: rows, columns: columns, now: now,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .paneSizeNoted(let pane, let rows, let columns, let now):
            reducePaneSizeNoted(
                pane: pane, rows: rows, columns: columns, now: now,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .viewportNoted(let rows, let columns):
            next.viewSize = .init(rows: rows, columns: columns)
        case .notice(let message):
            next.feedback = message
            next.feedbackTicks = 180
            presentationChanged = true
        case .tick(let now):
            reduceTick(now: now, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .reconnectFailed(let error):
            reduceReconnectFailed(error: error, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .reconnectSucceeded(let terminals):
            reduceReconnectSucceeded(
                terminals: terminals,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .hostDisconnected:
            reduceHostDisconnected(to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .writeCompleted(let binding, let bytes, let outcome):
            reduceWriteCompleted(
                binding: binding, bytes: bytes, outcome: outcome,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .acquireCompleted(let binding, let outcome):
            reduceAcquireCompleted(
                binding: binding, outcome: outcome,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .releaseInputCompleted(let binding, let outcome):
            reduceReleaseInputCompleted(
                binding: binding, outcome: outcome,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .resizeCompleted(let binding, let rows, let columns, let outcome, let now):
            reduceResizeCompleted(
                binding: binding, rows: rows, columns: columns, outcome: outcome, now: now,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .attachCompleted(let binding, let context, let outcome):
            reduceAttachCompleted(
                binding: binding, context: context, outcome: outcome,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .detachRequested:
            reduceDetachRequested(to: &next, effects: &effects, presentationChanged: &presentationChanged)
        }
        // Every transition ends here: stored lifecycles re-derive from
        // phases, so no observable state can contradict its phase.
        next.syncPaneLifecycles()
        if presentationChanged {
            next.presentationRevision &+= 1
        }
        return WorkspaceTUITransition(state: next, effects: effects)
    }
}
