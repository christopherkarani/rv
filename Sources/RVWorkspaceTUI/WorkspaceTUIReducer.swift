import Foundation

/// Closed lifecycle for one workspace shell session.
///
/// The previous model tracked this as `didConnect` / `connection` /
/// `didDetach` flags, which admitted impossible combinations. One enum keeps
/// every documented behavior while making invalid states unrepresentable:
/// - `neverConnected`: `connect()` has never succeeded. A later `connect()`
///   retries the describe/list query instead of failing fast.
/// - `connected`: the host is reachable; terminal I/O is allowed.
/// - `disconnected`: a query, RPC, or host event reported the host gone.
/// - `detached`: `detachSession()` ran. No transition leaves this state.
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
    /// Initial dimensions are configuration: set at init, never mutated.
    var initialRows: Int
    var initialColumns: Int
    var mode: CommandMode
    var terminal: AttachedTerminal?
    /// The runtime this client last acquired input for. A successful acquire
    /// RPC is authoritative over queued lease notifications (see
    /// `.inputOwner` handling below).
    var leasedRuntime: UUID?
    var retryAcquire: Bool
    var shouldExit: Bool
    var initialLaunchRequested: Bool
    var viewSize: ViewSize?
    var presentationRevision: UInt64
}

/// Inputs the reducer decides on. UI/host inputs and RPC completions share one
/// enum so a scripted event sequence fully determines the transitions.
enum WorkspaceTUIReducerEvent: Equatable, Sendable {
    case connectRequested
    case connectQuery(described: WorkspaceTUISummary, runtimes: [ListedRuntime])
    case connectQueryFailed
    case launchDefaultRequested
    case ensureSucceeded(runtime: ListedRuntime, shell: RuntimeLaunchChoice)
    case ensureFailed(disconnected: Bool)
    case key(TUIKey)
    case sendDue(runtime: UUID, bytes: Data)
    case launchDue(choice: RuntimeLaunchChoice)
    case launchQuerySucceeded(choice: RuntimeLaunchChoice, runtime: ListedRuntime, rows: Int, columns: Int)
    case launchQueryFailed
    case hostEvents([WorkspaceTUIEvent])
    case emulatorResponded(runtime: UUID, responses: [Data])
    case sizeNoted(rows: Int, columns: Int, now: Date)
    case tick(now: Date)
    case hostDisconnected
    case writeCompleted(runtime: UUID, outcome: TUIRPCOutcome)
    case acquireCompleted(runtime: UUID, outcome: TUIRPCOutcome)
    case resizeCompleted(runtime: UUID, outcome: TUIRPCOutcome)
    case subscribeCompleted(runtime: UUID, context: TUISubscribeContext, succeeded: Bool, disconnected: Bool)
    case detachRequested
}

/// One runtime action for the shell to execute. Effects never dispatch
/// themselves; the runtime owns queue choice and lock discipline.
enum TUIRuntimeEffect: Equatable, Sendable {
    /// Synchronous describe/list query. The runtime feeds the result back as
    /// `.connectQuery` or `.connectQueryFailed`.
    case queryConnect
    /// Synchronous ensure-or-reuse query for the default shell.
    case ensureShell(choice: RuntimeLaunchChoice, rows: Int, columns: Int)
    /// Key or emulator input to deliver on the terminal queue, re-gated there
    /// by `.sendDue` before the write RPC runs.
    case queueSend(runtime: UUID, bytes: Data)
    /// Launcher choice to run on the command queue, re-gated there by
    /// `.launchDue` before the launch RPC runs.
    case queueLaunch(choice: RuntimeLaunchChoice)
    /// Synchronous launch query. The runtime feeds the result back as
    /// `.launchQuerySucceeded` or `.launchQueryFailed`.
    case launchQuery(choice: RuntimeLaunchChoice, rows: Int, columns: Int)
    case subscribe(runtime: UUID, context: TUISubscribeContext)
    case unsubscribe(runtime: UUID)
    case acquire(runtime: UUID)
    case release(runtime: UUID)
    case write(runtime: UUID, bytes: Data)
    case resize(runtime: UUID, rows: Int, columns: Int)
    case cancel(runtime: UUID)
    case detach
    case createEmulator(runtime: UUID, rows: Int, columns: Int)
    case feedEmulator(runtime: UUID, data: Data)
    case resizeEmulator(runtime: UUID, rows: Int, columns: Int)
    case dropEmulator(runtime: UUID)
}

/// Why a subscribe was issued. Each origin handles subscribe failure
/// differently, so the context travels with the effect to its completion.
enum TUISubscribeContext: Equatable, Sendable {
    /// `connect()`: a non-disconnect failure still attempts acquisition.
    case connect
    /// `launchDefaultRuntimeIfEmpty()`: failure marks the terminal
    /// "(unavailable)" and read-only without acquiring.
    case ensure
    /// Replacement launch: failure drops the terminal, shows the launcher,
    /// and cancels the orphaned runtime.
    case launch
}

/// Outcome of one terminal-queue RPC, mapped from `WorkspaceTUIClientError`.
enum TUIRPCOutcome: Equatable, Sendable {
    case ok
    case busy
    case disconnected
    case unavailable
    case rejected

    static func from(_ result: Result<Void, WorkspaceTUIClientError>) -> Self {
        switch result {
        case .success: .ok
        case .failure(.busy): .busy
        case .failure(.disconnected): .disconnected
        case .failure(.unavailable): .unavailable
        case .failure(.rejected): .rejected
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
            presentationChanged = true
            let terminal = runtimes
                .filter(\.terminal)
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .first
            if let runtime = terminal {
                let rows = runtime.rows.map(Self.bound) ?? next.initialRows
                let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
                next.terminal = Self.attached(
                    runtime: runtime,
                    title: runtime.hook ?? "runtime",
                    rows: rows,
                    columns: columns
                )
                effects = [
                    .createEmulator(runtime: runtime.id, rows: rows, columns: columns),
                    .subscribe(runtime: runtime.id, context: .connect),
                ]
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
            guard let shell = next.launcher.first(where: { $0.id == "shell" }) else {
                next.mode = .launcher
                presentationChanged = true
                break
            }
            effects = [.ensureShell(choice: shell, rows: next.initialRows, columns: next.initialColumns)]

        case .ensureSucceeded(let runtime, let shell):
            guard next.lifecycle == .connected, next.shouldExit == false,
                  next.terminal == nil else { break }
            let rows = runtime.rows.map(Self.bound) ?? next.initialRows
            let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
            let title: String
            if let hook = runtime.hook {
                title = next.launcher.first(where: { $0.hook == hook })?.title ?? hook
            } else {
                title = runtime.created ? shell.title : "runtime"
            }
            next.terminal = Self.attached(runtime: runtime, title: title, rows: rows, columns: columns)
            presentationChanged = true
            effects = [
                .createEmulator(runtime: runtime.id, rows: rows, columns: columns),
                .subscribe(runtime: runtime.id, context: .ensure),
            ]

        case .ensureFailed(let disconnected):
            guard next.lifecycle == .connected else { break }
            if disconnected {
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                next.lifecycle = .disconnected
            } else if next.terminal == nil {
                next.mode = .launcher
                presentationChanged = true
            }

        case .key(let key):
            guard next.lifecycle != .detached, next.shouldExit == false else { break }
            let previousMode = next.mode
            let previousShouldExit = next.shouldExit
            let decision = CommandPrefix.route(
                key,
                mode: next.mode,
                launcher: next.launcher,
                directLauncherSelection: next.terminal?.state.running != true
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
            case .send(let bytes):
                if let runtime = Self.runtimeForInput(next) {
                    effects = [.queueSend(runtime: runtime, bytes: bytes)]
                }
            case .launch(let choice):
                effects = [.queueLaunch(choice: choice)]
            case .detach, .help, .dismissOverlay, nil:
                break
            }

        case .sendDue(let runtime, let bytes):
            // Re-gate on the terminal worker: the lease may have moved since
            // the key was pressed or the emulator replied.
            guard next.lifecycle == .connected, next.shouldExit == false,
                  next.leasedRuntime == runtime,
                  let terminal = next.terminal,
                  terminal.state.running, terminal.state.runtime == runtime else { break }
            effects = [.write(runtime: runtime, bytes: bytes)]

        case .launchDue(let choice):
            // Re-gate on the command worker: the request may have raced a
            // detach or another attach.
            guard next.lifecycle == .connected, next.shouldExit == false,
                  next.terminal?.state.running != true else { break }
            let size = next.viewSize ?? .init(rows: next.initialRows, columns: next.initialColumns)
            effects = [.launchQuery(choice: choice, rows: size.rows, columns: size.columns)]

        case .launchQuerySucceeded(let choice, let runtime, let rows, let columns):
            // A launch that races UI detach belongs to the workspace now.
            // Keep it alive so the next TUI invocation can rediscover it.
            guard next.lifecycle == .connected, next.shouldExit == false else { break }
            guard next.terminal?.state.running != true else {
                effects = [.cancel(runtime: runtime.id)]
                break
            }
            let oldRuntime = next.terminal?.state.runtime
            let oldSubscribed = next.terminal?.state.subscribed == true
            next.terminal = Self.attached(runtime: runtime, title: choice.title, rows: rows, columns: columns)
            next.mode = .terminal
            presentationChanged = true
            effects = [.createEmulator(runtime: runtime.id, rows: rows, columns: columns)]
            if oldSubscribed, let oldRuntime {
                effects.append(.unsubscribe(runtime: oldRuntime))
            }
            effects.append(.subscribe(runtime: runtime.id, context: .launch))

        case .launchQueryFailed:
            guard next.lifecycle == .connected else { break }
            next.mode = .launcher
            presentationChanged = true

        case .hostEvents(let events):
            guard next.lifecycle == .connected else { break }
            for event in events {
                Self.applyHostEvent(event, to: &next, effects: &effects, presentationChanged: &presentationChanged)
            }

        case .emulatorResponded(let runtime, let responses):
            guard next.lifecycle == .connected, responses.isEmpty == false else { break }
            guard next.leasedRuntime == runtime,
                  let terminal = next.terminal,
                  terminal.state.runtime == runtime, terminal.state.lease == .owned else { break }
            effects = responses.map { .queueSend(runtime: runtime, bytes: $0) }

        case .sizeNoted(let rows, let columns, let now):
            // Called from the render pass: records geometry only, never an RPC.
            guard next.terminal != nil, next.lifecycle == .connected else { break }
            next.terminal?.resize.record(rows: rows, columns: columns, now: now)
            next.viewSize = .init(rows: rows, columns: columns)

        case .tick(let now):
            guard next.lifecycle == .connected else { break }
            if var terminal = next.terminal, let size = terminal.resize.flush(now: now) {
                next.terminal = terminal
                presentationChanged = true
                effects.append(.resizeEmulator(runtime: terminal.state.runtime, rows: size.rows, columns: size.columns))
                effects.append(.resize(runtime: terminal.state.runtime, rows: size.rows, columns: size.columns))
            }
            if let terminal = next.terminal,
               next.retryAcquire, terminal.state.lease == .readOnly {
                effects.append(.acquire(runtime: terminal.state.runtime))
            }
            next.retryAcquire = false

        case .hostDisconnected:
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
            if next.lifecycle == .connected {
                next.lifecycle = .disconnected
            }

        case .writeCompleted(let runtime, let outcome):
            switch outcome {
            case .busy:
                if next.terminal?.state.runtime == runtime {
                    presentationChanged = presentationChanged || next.terminal?.state.lease != .readOnly
                    next.terminal?.state.lease = .readOnly
                }
                if next.leasedRuntime == runtime {
                    next.leasedRuntime = nil
                }
            case .disconnected:
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            case .ok, .unavailable, .rejected:
                break
            }

        case .acquireCompleted(let runtime, let outcome):
            switch outcome {
            case .ok:
                // Release-after-acquire: a success that arrives after the
                // terminal moved on (or detached) must release the orphaned
                // lease instead of claiming it.
                let stillAvailable = next.lifecycle == .connected
                    && next.terminal?.state.runtime == runtime
                    && next.terminal?.state.running == true
                if stillAvailable {
                    if next.terminal?.state.lease != .owned {
                        presentationChanged = true
                    }
                    next.terminal?.state.lease = .owned
                    next.leasedRuntime = runtime
                } else {
                    effects = [.release(runtime: runtime)]
                }
            case .busy, .unavailable, .rejected:
                if next.terminal?.state.runtime == runtime {
                    if next.terminal?.state.lease != .readOnly {
                        presentationChanged = true
                    }
                    next.terminal?.state.lease = .readOnly
                }
            case .disconnected:
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            }

        case .resizeCompleted(let runtime, let outcome):
            switch outcome {
            case .disconnected:
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            case .unavailable:
                Self.applyRuntimeExited(runtime: runtime, to: &next, presentationChanged: &presentationChanged)
            case .ok, .busy, .rejected:
                break
            }

        case .subscribeCompleted(let runtime, let context, let succeeded, let disconnected):
            if succeeded {
                if next.terminal?.state.runtime == runtime {
                    next.terminal?.state.subscribed = true
                }
                effects = [.acquire(runtime: runtime)]
                break
            }
            if disconnected {
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                if next.lifecycle == .connected {
                    next.lifecycle = .disconnected
                }
            }
            switch context {
            case .connect:
                if next.terminal?.state.runtime == runtime {
                    next.terminal?.state.subscribed = false
                }
                if disconnected == false {
                    effects = [.acquire(runtime: runtime)]
                }
            case .ensure:
                if next.terminal?.state.runtime == runtime {
                    next.terminal?.state.title += " (unavailable)"
                    presentationChanged = presentationChanged || next.terminal?.state.lease != .readOnly
                    next.terminal?.state.lease = .readOnly
                    next.terminal?.state.subscribed = false
                }
            case .launch:
                if next.terminal?.state.runtime == runtime {
                    next.terminal = nil
                }
                if next.lifecycle == .connected {
                    next.mode = .launcher
                }
                presentationChanged = true
                effects = [.dropEmulator(runtime: runtime), .cancel(runtime: runtime)]
            }

        case .detachRequested:
            guard next.lifecycle != .detached else { break }
            next.lifecycle = .detached
            next.shouldExit = true
            presentationChanged = true
            if let lease = next.leasedRuntime {
                effects.append(.release(runtime: lease))
            }
            next.leasedRuntime = nil
            next.retryAcquire = false
            if next.terminal?.state.subscribed == true, let runtime = next.terminal?.state.runtime {
                effects.append(.unsubscribe(runtime: runtime))
            }
            next.terminal?.state.lease = .released
            next.terminal?.state.subscribed = false
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
        case .bytes(let runtime, let data):
            guard next.terminal?.state.runtime == runtime else { return }
            guard data.isEmpty == false else { return }
            effects.append(.feedEmulator(runtime: runtime, data: data))
            presentationChanged = true
        case .overflow(let runtime):
            guard next.terminal?.state.runtime == runtime else { return }
            if next.terminal?.state.overflowed != true {
                next.terminal?.state.overflowed = true
                presentationChanged = true
            }
        case .exited(let runtime, let status):
            guard next.terminal?.state.runtime == runtime else { return }
            if next.terminal?.state.running != false || next.terminal?.state.exitStatus != status
                || next.terminal?.state.lease != .released {
                presentationChanged = true
            }
            next.terminal?.state.running = false
            next.terminal?.state.exitStatus = status
            next.terminal?.state.lease = .released
            if next.leasedRuntime == runtime {
                next.leasedRuntime = nil
            }
            // The final output stays on screen; the launcher offers a
            // replacement runtime and number keys select it directly.
            if next.mode != .launcher {
                next.mode = .launcher
                presentationChanged = true
            }
        case .inputOwner(let runtime, let owned):
            guard next.terminal?.state.runtime == runtime else { return }
            if owned {
                // The host broadcasts only that an owner exists, not which
                // client owns it. Only our successful acquire RPC grants
                // local write authority.
                if next.leasedRuntime != runtime {
                    presentationChanged = presentationChanged || next.terminal?.state.lease != .readOnly
                    next.terminal?.state.lease = .readOnly
                }
            } else {
                // Notifications do not carry a lease generation. A queued
                // release from an earlier epoch may arrive after a later
                // acquire succeeded, so the successful acquire is
                // authoritative while this client still claims ownership.
                guard next.leasedRuntime != runtime else { return }
                presentationChanged = presentationChanged || next.terminal?.state.lease != .readOnly
                next.terminal?.state.lease = .readOnly
                if next.terminal?.state.running == true {
                    next.retryAcquire = true
                }
            }
        }
    }

    private static func applyDisconnect(to next: inout WorkspaceTUIState, presentationChanged: inout Bool) {
        presentationChanged = presentationChanged
            || next.lifecycle == .connected
            || next.terminal?.state.lease != .readOnly
            || next.terminal?.state.subscribed == true
        next.leasedRuntime = nil
        next.retryAcquire = false
        next.terminal?.state.lease = .readOnly
        next.terminal?.state.subscribed = false
    }

    private static func applyRuntimeExited(
        runtime: UUID,
        to next: inout WorkspaceTUIState,
        presentationChanged: inout Bool
    ) {
        guard next.terminal?.state.runtime == runtime else { return }
        var changed = next.terminal?.state.running != false || next.terminal?.state.exitStatus != nil
            || next.terminal?.state.lease != .released
        next.terminal?.state.running = false
        next.terminal?.state.exitStatus = nil
        next.terminal?.state.lease = .released
        if next.leasedRuntime == runtime {
            next.leasedRuntime = nil
        }
        if next.mode != .launcher {
            next.mode = .launcher
            changed = true
        }
        presentationChanged = presentationChanged || changed
    }

    private static func runtimeForInput(_ state: WorkspaceTUIState) -> UUID? {
        guard state.lifecycle == .connected, state.shouldExit == false,
              let terminal = state.terminal, terminal.state.running else { return nil }
        return terminal.state.runtime
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
