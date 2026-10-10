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
        case .failed:
            panes[paneID]?.phase = .failed(stale: terminal)
        case .missing:
            panes[paneID]?.phase = .missing(stale: terminal)
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
            // A fresh intent holds nothing else (typeahead, scroll,
            // claims, and retries all require a binding or a slot), so
            // dropping the record loses nothing. A relaunch intent keeps
            // its previous output as the stale terminal.
            if let previous = detail.previous {
                panes[paneID]?.phase = .failed(stale: previous)
            } else {
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
    mutating func setScrollAnchor(_ anchor: Int, for paneID: PaneID) {
        let generation = panes[paneID]?.scroll?.generation
            ?? bindingKey(for: paneID)?.generation ?? 0
        panes[paneID, default: PaneRuntime(phase: .missing(stale: nil))].scroll = ScrollPosition(
            anchor: anchor, generation: generation
        )
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
                    // A saved runtime that is gone. The record (with no
                    // stale terminal) holds scroll and typeahead for the
                    // pane until the navigator attaches a replacement.
                    next.panes[paneID] = PaneRuntime(phase: .missing(stale: nil))
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
                // renders in the footer so the cause is not silent. A
                // raced launch that already has a candidate in flight
                // keeps it; the in-flight attach still decides the pane.
                let message = Self.launchFailureMessage(error, profileID: profileID)
                next.failLaunch(for: target.pane, message: message)
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
                        // A fresh pane, so no record can exist yet.
                        next.panes[target.pane] = PaneRuntime(phase: .launching(LaunchDetail(
                            previous: nil, candidate: nil
                        )))
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
                        // A fresh pane, so no record can exist yet.
                        next.panes[target.pane] = PaneRuntime(phase: .launching(LaunchDetail(
                            previous: nil, candidate: nil
                        )))
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
                            if next.terminal(for: pane)?.state.subscribed == true
                                || next.panes[pane]?.leaseClaim == binding {
                                effects.append(.release(runtime: binding.runtime))
                            }
                            effects.append(.dropEmulator(binding: binding))
                        }
                        // The whole runtime record goes with the pane: the
                        // old maps left scroll, retry, and replay entries
                        // behind for dead panes, observable only as garbage
                        // in snapshots.
                        next.panes.removeValue(forKey: pane)
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
                    // Entering re-pins the generation and keeps a previous
                    // anchor (a re-entered mode resumes where it left off).
                    let anchor = next.panes[pane]?.scroll?.anchor ?? 0
                    let generation = next.bindingKey(for: pane)?.generation ?? 0
                    next.panes[pane, default: PaneRuntime(phase: .missing(stale: nil))].scroll = ScrollPosition(
                        anchor: anchor,
                        generation: generation
                    )
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
                    next.setScrollAnchor(
                        min(Self.scrollTopSentinel, max(0, (next.panes[pane]?.scroll?.anchor ?? 0) + step)),
                        for: pane
                    )
                    presentationChanged = true
                }
            case .scrollTop:
                if case .scroll(let pane) = next.mode {
                    // The sentinel means oldest retained; views clamp to the
                    // emulator's real history depth.
                    next.setScrollAnchor(Self.scrollTopSentinel, for: pane)
                    presentationChanged = true
                }
            case .scrollBottom:
                if case .scroll(let pane) = next.mode {
                    next.setScrollAnchor(0, for: pane)
                    presentationChanged = true
                }
            case .exitScroll:
                if case .scroll(let pane) = previousMode {
                    // Clearing is observably identical to the old
                    // anchor-0-plus-no-generation: anchors read 0 when
                    // absent, and staleness needs a generation to compare.
                    next.panes[pane]?.scroll = nil
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
            guard next.panes[binding.pane]?.leaseClaim == binding else {
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
                  next.terminal(for: binding.pane)?.state.running == true else { break }
            guard next.panes[binding.pane]?.leaseClaim == binding else {
                if next.queuePendingInput(bytes, for: binding) {
                    presentationChanged = true
                }
                break
            }
            effects = [.write(binding: binding, bytes: bytes)]

        case .launchDue(let target, let choice):
            // Re-gate on the command worker: the request may have raced a
            // detach or another attach. A running terminal does not block a
            // replacement: the success path stashes it as the previous
            // terminal and keeps the old output until the new subscription
            // attaches. The serial command queue plus the in-flight
            // candidate collapse rapid double submits; a residual
            // same-instant duplicate stays host-owned and discoverable,
            // never attached twice.
            guard next.lifecycle == .connected, next.shouldExit == false,
                  Self.matches(target, in: next),
                  next.panes[target.pane]?.phase.candidate == nil else { break }
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
            let slot = next.terminal(for: target.pane)
            if slot != nil {
                // Keep the old emulator and output until the replacement
                // subscription succeeds. A failed attach remains editable.
                next.panes[target.pane]?.phase = .launching(LaunchDetail(
                    previous: slot,
                    candidate: .init(binding: binding, terminal: candidate)
                ))
            } else {
                next.assignTerminal(candidate, to: target.pane)
                next.panes[target.pane]?.phase = .launching(LaunchDetail(
                    previous: nil,
                    candidate: .init(binding: binding, terminal: candidate)
                ))
                effects.append(.createEmulator(binding: binding, rows: rows, columns: columns))
            }
            if next.activePaneID == target.pane { next.mode = .terminal }
            presentationChanged = true
            effects.append(.attach(binding: binding, context: .launch))

        case .launchQueryFailed(let target, let choice, let error):
            guard next.lifecycle == .connected, Self.matches(target, in: next) else { break }
            let message = Self.launchFailureMessage(error, profileID: choice.resourceProfileID)
            // A raced duplicate query can fail while a newer candidate is
            // already in flight; failLaunch keeps the candidate, so the
            // pane reads attaching until that attach decides it.
            next.failLaunch(for: target.pane, message: message)
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
            guard next.panes[binding.pane]?.leaseClaim == binding,
                  next.bindingKey(for: binding.pane) == binding,
                  let terminal = next.terminal(for: binding.pane),
                  terminal.state.lease == .owned else { break }
            effects = responses.map { response in
                next.activeBindingKey == binding
                    ? .queueSend(binding: binding, bytes: response)
                    : .queueEmulatorResponse(binding: binding, bytes: response)
            }

        case .sizeNoted(let rows, let columns, let now):
            // Called from the render pass: records geometry only, never an RPC.
            guard next.lifecycle == .connected, let pane = next.activePaneID,
                  next.terminal(for: pane) != nil else { break }
            // Resize-only: the old spelling wrote back through the
            // terminal setter, which re-assigned the pane and wiped queued
            // typeahead on every render pass. Pane-scoped notes always
            // took this direct path; now both do.
            next.updateTerminal(pane) { $0.resize.record(rows: rows, columns: columns, now: now) }
            next.viewSize = .init(rows: rows + 2, columns: columns + 2)

        case .paneSizeNoted(let pane, let rows, let columns, let now):
            guard next.lifecycle == .connected, next.terminal(for: pane) != nil else { break }
            next.updateTerminal(pane) { $0.resize.record(rows: rows, columns: columns, now: now) }

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
                // Ownership validation runs before the coalescer: an
                // observer must not promote a size it cannot send, and
                // its emulator keeps the runtime's actual dimensions
                // until this client holds the lease.
                guard next.terminal(for: pane)?.state.lease == .owned,
                      var slot = next.terminal(for: pane),
                      let size = slot.resize.flush(now: now),
                      let binding = next.bindingKey(for: pane) else { continue }
                // Only a flushed size writes back: a nil flush may still
                // have cleared a settled pending entry, which stays
                // discarded exactly as before.
                next.setTerminal(slot, for: pane)
                presentationChanged = true
                effects.append(.resizeEmulator(binding: binding, rows: size.rows, columns: size.columns))
                effects.append(.resize(binding: binding, rows: size.rows, columns: size.columns))
            }
            let acquirePanes = next.panes.keys.filter {
                next.panes[$0]?.retries.contains(.acquire) == true
            }
            for pane in acquirePanes {
                guard next.terminal(for: pane)?.state.lease == .readOnly,
                      let binding = next.bindingKey(for: pane) else { continue }
                effects.append(.acquire(binding: binding))
            }
            for pane in acquirePanes {
                next.panes[pane]?.retries.remove(.acquire)
            }
            let subscribePanes = next.panes.keys.filter {
                next.panes[$0]?.retries.contains(.subscribe) == true
            }
            for pane in subscribePanes {
                guard let binding = next.bindingKey(for: pane),
                      next.terminal(for: pane)?.state.running == true,
                      next.terminal(for: pane)?.state.subscribed == false else { continue }
                effects.append(.attach(binding: binding, context: .resubscribeRetry))
            }
            for pane in subscribePanes {
                next.panes[pane]?.retries.remove(.subscribe)
            }
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
                          next.terminal(for: paneID)?.state.running == true,
                          next.terminal(for: paneID)?.state.subscribed == true else { continue }
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
                    if case .launching(let detail)? = next.panes[paneID]?.phase, detail.candidate == nil {
                        next.panes[paneID] = nil
                    }
                    continue
                }
                guard available.contains(binding.runtime) else {
                    if let stale = next.terminal(for: paneID) {
                        next.panes[paneID]?.phase = .missing(stale: stale)
                    } else if next.panes[paneID] == nil {
                        next.panes[paneID] = PaneRuntime(phase: .missing(stale: nil))
                    }
                    continue
                }
                if let stale = next.terminal(for: paneID) {
                    // Re-attach lands in the candidate slot under the
                    // current binding: no rebind, so no generation bump.
                    next.panes[paneID]?.phase = .launching(LaunchDetail(
                        previous: nil, candidate: .init(binding: binding, terminal: stale)
                    ))
                }
                // A slot-less pane keeps its record (or lack of one): with
                // no terminal to book the subscription on, the attach
                // below still issues and its success releases, exactly as
                // before — the pane keeps reading missing instead of
                // sticking on attaching.
                if next.panes[paneID]?.preDisconnectLease?.runtime == binding.runtime {
                    effects.append(.attach(binding: binding, context: .reconnect))
                } else {
                    effects.append(.observe(binding: binding, context: .reconnect))
                }
            }
            for paneID in next.panes.keys {
                next.panes[paneID]?.preDisconnectLease = nil
            }
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
                presentationChanged = presentationChanged
                    || next.terminal(for: binding.pane)?.state.lease != .readOnly
                next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
                next.dropLeaseClaim(binding)
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
                   next.terminal(for: binding.pane)?.state.running == true,
                   next.terminal(for: binding.pane)?.state.subscribed == true {
                    next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                        .retries.insert(.acquire)
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
                if next.terminal(for: binding.pane)?.state.running == true {
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
                    && next.terminal(for: binding.pane)?.state.running == true
                if stillAvailable {
                    if next.terminal(for: binding.pane)?.state.lease != .owned {
                        presentationChanged = true
                    }
                    next.updateTerminal(binding.pane) { $0.state.lease = .owned }
                    next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                        .leaseClaim = binding
                    if let bytes = next.takePendingInput(for: binding) {
                        effects.append(.write(binding: binding, bytes: bytes))
                    }
                } else if next.lifecycle != .connected
                    || next.panes.values.contains(where: { $0.leaseClaim?.runtime == binding.runtime }) == false {
                    effects = [.release(runtime: binding.runtime)]
                }
            case .busy:
                guard next.lifecycle != .detached else { break }
                if next.bindingKey(for: binding.pane) == binding {
                    if next.terminal(for: binding.pane)?.state.lease != .readOnly {
                        presentationChanged = true
                    }
                    next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
                }
            case .unavailable, .rejected:
                guard next.lifecycle != .detached else { break }
                guard next.bindingKey(for: binding.pane) == binding else { break }
                if next.terminal(for: binding.pane)?.state.lease != .readOnly {
                    presentationChanged = true
                }
                next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
                // Acquire fails unavailable only when the host has no
                // subscription for this client (a silent overflow drop) or
                // the runtime is gone. A pane that believes it is subscribed
                // re-attaches; behind a gone runtime the attach outcome (or
                // its exited notice) converges instead of looping.
                if next.lifecycle == .connected,
                   next.terminal(for: binding.pane)?.state.running == true,
                   next.terminal(for: binding.pane)?.state.subscribed == true {
                    next.updateTerminal(binding.pane) { $0.state.subscribed = false }
                    next.panes[binding.pane]?.retries.remove(.subscribe)
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
                    || next.terminal(for: binding.pane)?.state.lease != .readOnly
                next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
                next.dropLeaseClaim(binding)
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
                    || next.terminal(for: binding.pane)?.state.lease != .readOnly
                next.updateTerminal(binding.pane) {
                    $0.state.lease = .readOnly
                    $0.resize.nack(rows: rows, columns: columns, now: now)
                }
                next.dropLeaseClaim(binding)
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
               case .launching(let detail)? = next.panes[binding.pane]?.phase,
               let candidate = detail.candidate, candidate.binding == binding,
               let previousTerminal = detail.previous {
                // Replacement only: a fresh launch (no previous terminal)
                // flows to the main branch below, exactly as before.
                switch outcome {
                case .owned, .readOnly:
                    let previousKey = next.bindingKey(for: binding.pane)
                    let wasSubscribed = previousTerminal.state.subscribed
                    next.assignTerminal(candidate.terminal, to: binding.pane)
                    next.updateTerminal(binding.pane) {
                        $0.state.subscribed = true
                        $0.state.lease = outcome == .owned ? .owned : .readOnly
                    }
                    next.updatePane(binding.pane) { $0.lastOutcome = nil }
                    if outcome == .owned {
                        next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                            .leaseClaim = binding
                    }
                    if let previousKey {
                        // assignTerminal already dropped the old claim, so
                        // the old post-assign membership check could never
                        // fire: only a subscribed previous runtime is
                        // released. (The navigator path checks before
                        // assigning and differs; both keep their
                        // historical behavior.)
                        if wasSubscribed {
                            effects.append(.release(runtime: previousKey.runtime))
                        }
                        effects.append(.dropEmulator(binding: previousKey))
                    }
                    let size = candidate.terminal.resize.effectiveSize
                        ?? (rows: next.initialRows, columns: next.initialColumns)
                    effects.append(.createEmulator(
                        binding: binding, rows: size.rows, columns: size.columns
                    ))
                case .unavailable, .disconnected:
                    next.panes[binding.pane]?.phase = .failed(stale: previousTerminal)
                    next.updatePane(binding.pane) {
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
                    && next.terminal(for: binding.pane)?.state.running == true
                if stillAvailable {
                    if next.terminal(for: binding.pane)?.state.lease != .owned {
                        presentationChanged = true
                    }
                    next.updateTerminal(binding.pane) {
                        $0.state.subscribed = true
                        $0.state.lease = .owned
                    }
                    if context == .resubscribe || context == .resubscribeRetry {
                        next.updateTerminal(binding.pane) { $0.state.overflowed = false }
                        next.panes[binding.pane]?.retries.remove(.subscribe)
                        presentationChanged = true
                    }
                    next.landAttach(for: binding)
                    next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                        .leaseClaim = binding
                    if let bytes = next.takePendingInput(for: binding) {
                        effects.append(.write(binding: binding, bytes: bytes))
                    }
                } else if next.panes.values.contains(where: { $0.leaseClaim?.runtime == binding.runtime }) == false {
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
                    if next.panes[binding.pane]?.leaseClaim == binding {
                        next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                            .retries.insert(.acquire)
                    }
                    presentationChanged = true
                    break
                }
                if next.terminal(for: binding.pane)?.state.lease != .readOnly {
                    presentationChanged = true
                }
                next.updateTerminal(binding.pane) {
                    $0.state.subscribed = true
                    $0.state.lease = .readOnly
                }
                if context == .resubscribe || context == .resubscribeRetry {
                    next.updateTerminal(binding.pane) { $0.state.overflowed = false }
                    next.panes[binding.pane]?.retries.remove(.subscribe)
                    presentationChanged = true
                }
                next.landAttach(for: binding)
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
                        if next.terminal(for: binding.pane)?.state.lease != .readOnly {
                            presentationChanged = true
                        }
                        next.updateTerminal(binding.pane) {
                            $0.state.subscribed = false
                            $0.state.lease = .readOnly
                        }
                    }
                case .ensure:
                    presentationChanged = presentationChanged
                        || next.terminal(for: binding.pane)?.state.lease != .readOnly
                    next.updateTerminal(binding.pane) {
                        $0.state.title += " (unavailable)"
                        $0.state.lease = .readOnly
                        $0.state.subscribed = false
                    }
                case .launch:
                    // A stale launch failure (for an older binding while a
                    // newer candidate is in flight) must not clobber the
                    // candidate: the in-flight attach still decides. Only
                    // failures for the live candidate, or with no
                    // candidate, fail the pane.
                    switch next.panes[binding.pane]?.phase {
                    case .launching(let detail) where detail.candidate != nil
                        && detail.candidate?.binding != binding:
                        break
                    default:
                        next.updatePane(binding.pane) {
                            $0.lastOutcome = .launchFailed("Terminal attach failed")
                        }
                        if case .launching(let detail)? = next.panes[binding.pane]?.phase,
                           detail.previous == nil, detail.candidate?.binding == binding {
                            next.panes[binding.pane]?.phase = .failed(stale: detail.candidate?.terminal)
                        } else if let slot = next.terminal(for: binding.pane) {
                            next.panes[binding.pane]?.phase = .failed(stale: slot)
                        } else {
                            next.panes[binding.pane]?.phase = .failed(stale: nil)
                        }
                    }
                    if next.activePaneID == binding.pane, next.lifecycle == .connected {
                        next.mode = .launcher
                    }
                    presentationChanged = true
                case .reconnect:
                    if let slot = next.terminal(for: binding.pane) {
                        next.panes[binding.pane]?.phase = .missing(stale: slot)
                    }
                    presentationChanged = true
                case .resubscribe:
                    // The drop races this RPC across connections; the tick
                    // retries until the subscribe lands. The lease is left
                    // alone: a stale owned claim renders behind the
                    // skipped-output indicator and self-heals on send, while
                    // read-only would spam acquires that fail closed without
                    // a subscription.
                    if outcome == .unavailable {
                        next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                            .retries.insert(.subscribe)
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
            var releases = next.panes.values.compactMap { $0.leaseClaim?.runtime }
            for slot in next.panes.values.compactMap(\.terminal) where slot.state.subscribed {
                if releases.contains(slot.state.runtime) == false { releases.append(slot.state.runtime) }
            }
            effects.append(contentsOf: releases.map(TUIRuntimeEffect.release))
            for pane in next.panes.keys {
                next.panes[pane]?.leaseClaim = nil
                next.panes[pane]?.retries = []
                next.panes[pane]?.input = nil
                next.updateTerminal(pane) {
                    $0.state.lease = .released
                    $0.state.subscribed = false
                }
            }
            effects.append(.detach)
        }
        // Every transition ends here: stored lifecycles re-derive from
        // phases, so no observable state can contradict its phase.
        next.syncPaneLifecycles()
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
                  let terminal = next.terminal(for: pane) else { return }
            next.panes[pane]?.replayBatch = batch
            next.panes[pane]?.recentOutputOnly = truncated
            let size = terminal.resize.effectiveSize
                ?? (rows: next.initialRows, columns: next.initialColumns)
            effects.append(.createEmulator(binding: binding, rows: size.rows, columns: size.columns))
            presentationChanged = true
        case .replayEnd(let runtime, let batch):
            guard let pane = next.paneID(for: runtime),
                  next.panes[pane]?.replayBatch == batch else { return }
            next.panes[pane]?.replayBatch = nil
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
                  next.terminal(for: pane)?.state.running == true else { return }
            if next.terminal(for: pane)?.state.overflowed != true {
                next.updateTerminal(pane) { $0.state.overflowed = true }
            }
            // The host dropped this subscription; without a resubscribe the
            // pane goes dark and input acquire fails closed. The overflow
            // notice is already on the wire, so the same client id may
            // subscribe again immediately; a cross-connection race lands in
            // the tick retry set through the failure branch below.
            next.updateTerminal(pane) { $0.state.subscribed = false }
            next.panes[pane]?.retries.remove(.subscribe)
            effects.append(.attach(binding: binding, context: .resubscribe))
            presentationChanged = true
        case .window(let runtime, let rows, let columns):
            // Actual PTY dimensions, published by the owner's resize. Only
            // observers apply them: the owner drives its emulator from its
            // own coalescer and must not have it rewritten underneath.
            // The desired claim (not the observed lease) decides: a
            // contended claimant keeps its size while it re-acquires.
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane),
                  next.panes[pane]?.leaseClaim != binding,
                  next.terminal(for: pane)?.state.running == true else { return }
            effects.append(.resizeEmulator(binding: binding, rows: rows, columns: columns))
            presentationChanged = true
        case .exited(let runtime, let status):
            guard let pane = next.paneID(for: runtime) else { return }
            if next.terminal(for: pane)?.state.running != false
                || next.terminal(for: pane)?.state.exitStatus != status
                || next.terminal(for: pane)?.state.lease != .released {
                presentationChanged = true
            }
            next.markExited(pane, status: status)
            next.updatePane(pane) { $0.lastOutcome = .exited(status) }
            if let binding = next.bindingKey(for: pane) {
                next.dropLeaseClaim(binding)
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
                if next.panes[pane]?.leaseClaim != binding {
                    presentationChanged = presentationChanged
                        || next.terminal(for: pane)?.state.lease != .readOnly
                    next.updateTerminal(pane) { $0.state.lease = .readOnly }
                }
            } else {
                // Notifications do not carry a lease generation. A queued
                // release from an earlier epoch may arrive after a later
                // acquire succeeded, so the successful acquire is
                // authoritative while this client still claims ownership.
                guard next.panes[pane]?.leaseClaim != binding else { return }
                presentationChanged = presentationChanged
                    || next.terminal(for: pane)?.state.lease != .readOnly
                next.updateTerminal(pane) { $0.state.lease = .readOnly }
                if next.terminal(for: pane)?.state.running == true {
                    next.panes[pane, default: PaneRuntime(phase: .missing(stale: nil))]
                        .retries.insert(.acquire)
                }
            }
        }
    }

    private static func applyDisconnect(to next: inout WorkspaceTUIState, presentationChanged: inout Bool) {
        presentationChanged = presentationChanged
            || next.lifecycle == .connected
            || next.panes.values.contains {
                guard let state = $0.terminal?.state else { return false }
                return state.lease != .readOnly || state.subscribed || state.overflowed
            }
        // A second disconnect during reattach must not clobber the original
        // stash with an empty in-flight set.
        if next.panes.values.contains(where: { $0.leaseClaim != nil }) {
            for pane in next.panes.keys {
                let claim = next.panes[pane]?.leaseClaim
                next.panes[pane]?.preDisconnectLease = claim
            }
        }
        for pane in next.panes.keys {
            next.panes[pane]?.leaseClaim = nil
            next.panes[pane]?.retries = []
            // Only panes with a terminal slot flip: a slot-less launch
            // intent or missing record survives the outage untouched. An
            // in-flight candidate is dropped with its launch: the pane
            // keeps the stale terminal, and a late attach completion for
            // the candidate releases instead of claiming on a dead
            // connection (fail closed; the runtime stays discoverable).
            if let slot = next.terminal(for: pane) {
                var stale = slot
                stale.state.lease = .readOnly
                stale.state.subscribed = false
                stale.state.overflowed = false
                next.panes[pane]?.phase = .disconnected(stale: stale)
            }
        }
    }

    private static func applyRuntimeExited(
        runtime: UUID,
        to next: inout WorkspaceTUIState,
        presentationChanged: inout Bool
    ) {
        guard let pane = next.paneID(for: runtime) else { return }
        var changed = next.terminal(for: pane)?.state.running != false
            || next.terminal(for: pane)?.state.exitStatus != nil
            || next.terminal(for: pane)?.state.lease != .released
        next.markExited(pane, status: nil)
        if let binding = next.bindingKey(for: pane) {
            next.dropLeaseClaim(binding)
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
        guard let expected = state.panes[pane]?.scroll?.generation else { return false }
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
           state.terminal(for: pane)?.state.running == true,
           let binding = state.bindingKey(for: pane) {
            items.append(state.panes[pane]?.leaseClaim == binding ? .releaseInput : .acquireInput)
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
            guard next.terminal(for: pane)?.state.running != true,
                  let runtime = next.knownRuntimes.first(where: { $0.id == id }),
                  next.paneID(for: id) == nil else {
                next.feedback = "Runtime is no longer available"
                next.feedbackTicks = 60
                presentationChanged = true
                return
            }
            let previous = next.bindingKey(for: pane)
            let wasSubscribed = next.terminal(for: pane)?.state.subscribed == true
            let wasLeased = previous.map { next.panes[pane]?.leaseClaim == $0 } ?? false
            let rows = runtime.rows.map(Self.bound) ?? next.initialRows
            let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
            next.assignTerminal(Self.attached(
                runtime: runtime, title: runtime.hook ?? "runtime", rows: rows, columns: columns
            ), to: pane)
            if let binding = next.bindingKey(for: pane) {
                effects.append(.createEmulator(binding: binding, rows: rows, columns: columns))
                effects.append(.attach(binding: binding, context: .launch))
                // A fresh attach with no previous terminal: the
                // completion flows through the main branch, as before.
                if let slot = next.terminal(for: pane) {
                    next.panes[pane]?.phase = .launching(LaunchDetail(
                        previous: nil, candidate: .init(binding: binding, terminal: slot)
                    ))
                }
            }
            if let previous, previous.runtime != id, wasSubscribed || wasLeased {
                effects.append(.release(runtime: previous.runtime))
            }
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
            // A fresh pane, so no record can exist yet.
            next.panes[pane] = PaneRuntime(phase: .launching(LaunchDetail(
                previous: nil, candidate: nil
            )))
        }
        return true
    }

    /// Enter on a dead pane starts a new default shell in place. Returns the
    /// launch effect, or nil when the pane is live, the host is unreachable,
    /// or no default shell is configured. Never reruns previous argv.
    private static func relaunchFocusedShell(into next: inout WorkspaceTUIState) -> TUIRuntimeEffect? {
        guard next.lifecycle == .connected,
              let pane = next.activePaneID,
              next.terminal(for: pane)?.state.running != true,
              Self.isRelaunchable(next.panes[pane]?.phase, binding: next.view.panes[pane]?.binding),
              let target = Self.target(next),
              let shell = Self.defaultShell(next) else { return nil }
        // The intent keeps the current output (and every other field)
        // until the replacement lands.
        var runtime = next.panes[pane] ?? PaneRuntime(phase: .launching(LaunchDetail(
            previous: nil, candidate: nil
        )))
        runtime.phase = .launching(LaunchDetail(previous: runtime.terminal, candidate: nil))
        next.panes[pane] = runtime
        return .queueLaunch(target: target, choice: shell)
    }

    /// Relaunchable phases: an exited terminal, a failed launch, or an
    /// unbound pane with no record. Mirrors the old
    /// [.empty, .exited, .launchFailed] lifecycle check against the
    /// phases the sync derives those lifecycles from.
    private static func isRelaunchable(_ phase: PanePhase?, binding: RuntimeBinding?) -> Bool {
        switch phase {
        case .attached(let terminal):
            return terminal.state.running == false
        case .failed:
            return true
        case .launching, .missing, .disconnected:
            return false
        case nil:
            return binding == nil
        }
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
        if let size = state.terminal(for: pane)?.resize.effectiveSize {
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
