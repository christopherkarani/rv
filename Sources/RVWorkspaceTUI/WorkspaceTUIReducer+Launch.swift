import Foundation
import RVDomain

// Launch and run-command transitions, plus pane targeting helpers.
extension WorkspaceTUIReducer {
    static func reduceRunCommandResolved(
        target: PrefixTarget,
        choice: RuntimeLaunchChoice,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, Self.matches(target, in: next) else { return }
        // Success closes the overlay so the replacement is visible;
        // failures keep the editable input via .runCommandFailed.
        next.mode = .terminal
        effects = [.queueLaunch(target: target, choice: choice)]
        presentationChanged = true
    }

    static func reduceRunCommandFailed(
        target: PrefixTarget,
        message: String,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, Self.matches(target, in: next),
              case .runCommand(let input, _) = next.mode else { return }
        next.mode = .runCommand(input: input, error: message)
        next.updatePane(target.pane) {
            $0.lastOutcome = .launchFailed(message)
        }
        presentationChanged = true
    }

    static func reduceLaunchDue(
        target: PrefixTarget,
        choice: RuntimeLaunchChoice,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
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
              next.panes[target.pane]?.phase.candidate == nil else { return }
        let size = Self.launchSize(for: target.pane, in: next)
        effects = [.launchQuery(target: target, choice: choice, rows: size.rows, columns: size.columns)]
    }

    static func reduceLaunchQuerySucceeded(
        target: PrefixTarget,
        choice: RuntimeLaunchChoice,
        runtime: ListedRuntime,
        rows: Int,
        columns: Int,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // A launch that races UI detach belongs to the workspace now.
        // Keep it alive so the next TUI invocation can rediscover it.
        guard next.lifecycle == .connected, next.shouldExit == false,
              Self.matches(target, in: next) else { return }
        // A completed launch belongs to the host even if this view
        // changed while the RPC was in flight. Stale generations are
        // dropped by matches() above; a success for a live pane is an
        // intentional replacement and flows into the pending branch
        // below, which keeps the old output until the new attach lands.
        guard next.paneID(for: runtime.id) == nil else { return }
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
    }

    static func reduceLaunchQueryFailed(
        target: PrefixTarget,
        choice: RuntimeLaunchChoice,
        error: WorkspaceTUIError,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, Self.matches(target, in: next) else { return }
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
    }

    /// Creates a tab for a launcher/run-command choice when the view is
    /// intentionally empty. Returns true when it changed the layout.
    static func ensureLaunchPane(into next: inout WorkspaceTUIState) -> Bool {
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
    static func relaunchFocusedShell(into next: inout WorkspaceTUIState) -> TUIRuntimeEffect? {
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

    static func target(_ state: WorkspaceTUIState) -> PrefixTarget? {
        state.activePaneID.map { PrefixTarget(pane: $0, generation: state.activeBindingKey?.generation) }
    }

    static func matches(_ target: PrefixTarget, in state: WorkspaceTUIState) -> Bool {
        guard state.view.panes[target.pane] != nil else { return false }
        return state.bindingKey(for: target.pane)?.generation == target.generation
    }

    static func viewport(_ state: WorkspaceTUIState) -> CellRect {
        let size = state.viewSize ?? .init(rows: state.initialRows + 2, columns: state.initialColumns + 2)
        return CellRect(x: 0, y: 0, width: max(1, size.columns), height: max(1, size.rows))
    }

    static func defaultShell(_ state: WorkspaceTUIState) -> RuntimeLaunchChoice? {
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

    static func launchFailureMessage(_ error: WorkspaceTUIError, profileID: String?) -> String {
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
}
