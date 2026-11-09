import Foundation
import RVDomain

// Connect, ensure, reconnect, disconnect, and detach transitions.
extension WorkspaceTUIReducer {
    static func reduceConnectQuery(
        described: WorkspaceTUISummary,
        runtimes: [ListedRuntime],
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .neverConnected else { return }
        next.summary = described
        next.lifecycle = .connected
        next.knownRuntimes = runtimes.sorted { $0.id.uuidString < $1.id.uuidString }
        presentationChanged = true
        let available = Dictionary(uniqueKeysWithValues: runtimes.filter(\.terminal).map { ($0.id, $0) })
        for paneID in next.view.panes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let saved = next.view.panes[paneID]?.binding else { continue }
            guard saved.workspace.rawValue == described.workspace,
                  let runtime = available[saved.runtime.rawValue] else {
                // A saved runtime that is gone. An existing record
                // keeps scroll, typeahead, and its other non-phase
                // fields; only the phase becomes missing. Replacing
                // the record would drop a scroll pinned before
                // inventory. The navigator attaches a replacement
                // onto this slot-less missing record.
                var record = next.panes[paneID] ?? PaneRuntime(phase: .missing(stale: nil))
                record.phase = .missing(stale: nil)
                next.panes[paneID] = record
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
    }

    static func reduceConnectQueryFailed(
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .neverConnected else { return }
        // A failed first query stays retryable: the lifecycle deliberately
        // does not advance to `.disconnected`.
        Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
    }

    static func reduceLaunchDefaultRequested(
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, next.shouldExit == false,
              next.terminal == nil, next.initialLaunchRequested == false else { return }
        next.initialLaunchRequested = true
        guard let shell = Self.defaultShell(next) else {
            next.mode = .launcher
            presentationChanged = true
            return
        }
        guard let target = Self.target(next) else { return }
        effects = [.ensureShell(target: target, choice: shell, rows: next.initialRows, columns: next.initialColumns)]
    }

    static func reduceEnsureSucceeded(
        target: PrefixTarget,
        runtime: ListedRuntime,
        shell: RuntimeLaunchChoice,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, next.shouldExit == false,
              Self.target(next) == target, next.terminal == nil else { return }
        let rows = runtime.rows.map(Self.bound) ?? next.initialRows
        let columns = runtime.columns.map(Self.bound) ?? next.initialColumns
        let title: String
        if let hook = runtime.hook {
            title = next.launcher.first(where: { $0.hook == hook })?.title ?? hook
        } else {
            title = runtime.created ? shell.title : "runtime"
        }
        next.terminal = Self.attached(runtime: runtime, title: title, rows: rows, columns: columns)
        guard let binding = next.activeBindingKey else { return }
        presentationChanged = true
        effects = [
            .createEmulator(binding: binding, rows: rows, columns: columns),
            .attach(binding: binding, context: .ensure),
        ]
    }

    static func reduceEnsureFailed(
        target: PrefixTarget,
        error: WorkspaceTUIError,
        profileID: String?,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, Self.target(next) == target else { return }
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
    }

    static func reduceReconnectFailed(
        error: WorkspaceTUIError,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .disconnected else { return }
        next.reconnectInflight = false
        if error == .incompatibleHost {
            next.reconnectFiresAt = nil
            // Spend the budget so the next tick does not re-arm; Enter resets it.
            next.reconnectAttempt = Self.maxReconnectAttempts
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
    }

    static func reduceReconnectSucceeded(
        terminals: [ListedRuntime],
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .disconnected else { return }
        next.lifecycle = .connected
        next.reconnectAttempt = 0
        next.reconnectInflight = false
        next.reconnectFiresAt = nil
        next.knownRuntimes = terminals.sorted { $0.id.uuidString < $1.id.uuidString }
        next.feedback = "Reconnected"
        next.feedbackTicks = 60
        let available = Set(terminals.map(\.id))
        for paneID in next.view.panes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            reconcileReconnectedPane(paneID, available: available, to: &next, effects: &effects)
        }
        for paneID in next.panes.keys {
            next.panes[paneID]?.preDisconnectLease = nil
        }
        effects.append(.restartEvents)
        presentationChanged = true
    }

    private static func reconcileReconnectedPane(
        _ paneID: PaneID,
        available: Set<UUID>,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect]
    ) {
        guard let binding = next.bindingKey(for: paneID) else {
            // An ambiguous launch never retries blindly: the pane
            // returns to empty and any orphaned runtime stays
            // discoverable through the refreshed inventory.
            if case .launching(let detail)? = next.panes[paneID]?.phase, detail.candidate == nil {
                next.panes[paneID] = nil
            }
            return
        }
        guard available.contains(binding.runtime) else {
            if let stale = next.terminal(for: paneID) {
                next.panes[paneID]?.phase = .missing(stale: stale)
            } else {
                // No slot: an existing record (a slot-less
                // .launching left when the query returned during
                // the outage, or a restored .missing/.failed)
                // becomes .missing. Creating a record only when
                // absent would leave .launching stuck, and Enter
                // cannot start another shell from that phase.
                var runtime = next.panes[paneID] ?? PaneRuntime(phase: .missing(stale: nil))
                runtime.phase = .missing(stale: nil)
                next.panes[paneID] = runtime
            }
            return
        }
        if let stale = next.terminal(for: paneID) {
            if stale.state.running {
                // Re-attach lands in the candidate slot under the
                // current binding: no rebind, so no generation bump.
                // Only a running terminal gets a candidate. Observe
                // and attach complete and landAttach clears it.
                next.panes[paneID]?.phase = .launching(LaunchDetail(
                    previous: nil, candidate: .init(binding: binding, terminal: stale)
                ))
            } else {
                // A dead terminal is already exited. A candidate
                // would derive attaching and close the launch gate,
                // and observe is dropped while the terminal is not
                // running, so nothing would clear it. Rest on the
                // stale terminal with no candidate and no reattach.
                next.panes[paneID]?.phase = .attached(stale)
            }
        } else if case .launching? = next.panes[paneID]?.phase {
            // No slot: a .launching record (the query returned
            // during the outage) would stay .launching. landAttach
            // no-ops without a slot, and Enter cannot retry.
            // Collapse it the way the absent-runtime branch does,
            // keeping scroll and the other non-phase fields.
            var record = next.panes[paneID] ?? PaneRuntime(phase: .missing(stale: nil))
            record.phase = .missing(stale: nil)
            next.panes[paneID] = record
        }
        // A slot-less pane keeps its record (or lack of one): with
        // no terminal to book the subscription on, the attach
        // below still issues and its success releases, exactly as
        // before — the pane keeps reading missing instead of
        // sticking on attaching. A non-running stale terminal
        // does not reattach; that effect would never land.
        if next.terminal(for: paneID)?.state.running != false {
            if next.panes[paneID]?.preDisconnectLease?.runtime == binding.runtime {
                effects.append(.attach(binding: binding, context: .reconnect))
            } else {
                effects.append(.observe(binding: binding, context: .reconnect))
            }
        }
    }

    static func reduceHostDisconnected(
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // A disconnect that races detach must not resurrect the lease:
        // detached already released it and reported shouldExit.
        guard next.lifecycle != .detached else { return }
        Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
        if next.lifecycle == .connected {
            next.lifecycle = .disconnected
        }
    }

    static func reduceDetachRequested(
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle != .detached else { return }
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

    static func applyDisconnect(to next: inout WorkspaceTUIState, presentationChanged: inout Bool) {
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

    /// Bounded reconnect: twelve attempts over roughly a minute, then the
    /// view stays on its preserved output until the user retries or detaches.
    static let maxReconnectAttempts = 12

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(8.0, 0.25 * pow(2.0, Double(max(0, attempt))))
    }

    static func tickReconnect(
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

    static func attached(
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

    static func bound(_ value: Int) -> Int {
        min(512, max(1, value))
    }
}
