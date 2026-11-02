import Foundation
import RVDomain

// Key, paste, and prefix-command transitions, plus the navigator.
extension WorkspaceTUIReducer {
    static func reduceKey(
        _ key: TUIKey,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle != .detached, next.shouldExit == false else { return }
        if next.lifecycle == .disconnected, key == .enter, next.mode == .terminal {
            // Manual retry after the bounded schedule gave up. The next
            // tick schedules the attempt; nothing is sent to any runtime.
            next.reconnectAttempt = 0
            next.reconnectInflight = false
            next.reconnectFiresAt = nil
            next.feedback = "Reconnecting…"
            next.feedbackTicks = 60
            presentationChanged = true
            return
        }
        if case .prefix(let target) = next.mode,
           target != next.activePaneID.map({ PrefixTarget(pane: $0, generation: next.activeBindingKey?.generation) }) {
            next.mode = .terminal
            next.feedback = "Pane changed; command cancelled"
            next.feedbackTicks = 60
            presentationChanged = true
            return
        }
        if case .scroll(let pane) = next.mode, Self.scrollStale(pane, in: next) {
            next.mode = .terminal
            next.feedback = "Pane changed; scroll cancelled"
            next.feedbackTicks = 60
            presentationChanged = true
            return
        }
        if case .confirmCancel(let pane) = next.mode, next.view.panes[pane] == nil {
            next.mode = .terminal
            next.feedback = "Pane changed; cancelled"
            next.feedbackTicks = 60
            presentationChanged = true
            return
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
        applyCommand(
            decision.1,
            previousMode: previousMode,
            navigatorIndexBefore: navigatorIndexBefore,
            confirmPaneBefore: confirmPaneBefore,
            to: &next, effects: &effects, presentationChanged: &presentationChanged
        )
    }

    private static func applyCommand(
        _ command: TUICommand?,
        previousMode: CommandMode,
        navigatorIndexBefore: Int?,
        confirmPaneBefore: PaneID?,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard let command else { return }
        switch command {
        case .sendKey, .send, .acquireInput, .releaseInput, .relaunchShell, .launch, .submitRunCommand,
             .invalidPrefix:
            applyInputCommand(command, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .openLauncher, .split, .focus, .newTab, .switchTab, .closePane, .toggleZoom, .enterResize,
             .resizeStep:
            applyLayoutCommand(command, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        case .enterScroll, .scrollDelta, .scrollTop, .scrollBottom, .exitScroll:
            applyScrollCommand(
                command, previousMode: previousMode,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .enterNavigator, .navigatorMove, .navigatorActivate, .enterConfirmCancel, .confirmCancel:
            applyNavigatorCommand(
                command, navigatorIndexBefore: navigatorIndexBefore, confirmPaneBefore: confirmPaneBefore,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .detach, .help, .dismissOverlay, .finishResize, .exitNavigator, .dismissConfirm:
            break
        }
    }

    private static func applyInputCommand(
        _ command: TUICommand,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch command {
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
        default:
            break
        }
    }

    private static func applyLayoutCommand(
        _ command: TUICommand,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch command {
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
            closeFocusedPane(to: &next, effects: &effects, presentationChanged: &presentationChanged)
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
        default:
            break
        }
    }

    private static func closeFocusedPane(
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
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
    }

    private static func applyScrollCommand(
        _ command: TUICommand,
        previousMode: CommandMode,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch command {
        case .enterScroll:
            if case .scroll(let pane) = next.mode, next.view.panes[pane]?.binding != nil {
                // Entering re-pins the generation and keeps a previous
                // anchor (a re-entered mode resumes where it left off).
                // No record means there is nothing to pin: inserting
                // `.missing` would flip chrome to "runtime missing"
                // before connect, and the anchor reads as 0 anyway.
                if next.panes[pane] != nil {
                    let anchor = next.panes[pane]?.scroll?.anchor ?? 0
                    let generation = next.bindingKey(for: pane)?.generation ?? 0
                    next.panes[pane]?.scroll = ScrollPosition(
                        anchor: anchor,
                        generation: generation
                    )
                }
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
        default:
            break
        }
    }

    private static func applyNavigatorCommand(
        _ command: TUICommand,
        navigatorIndexBefore: Int?,
        confirmPaneBefore: PaneID?,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch command {
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
        default:
            break
        }
    }

    static func reducePaste(
        _ text: String,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, next.shouldExit == false else { return }
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
    }

    static func reduceInventoryRefreshed(
        terminals: [ListedRuntime],
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected else { return }
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
    }

    private static func bindingForInput(_ state: WorkspaceTUIState) -> PaneBindingKey? {
        guard state.lifecycle == .connected, state.shouldExit == false,
              let terminal = state.terminal, terminal.state.running else { return nil }
        return state.activeBindingKey
    }

    /// Sentinel anchor meaning oldest retained output. Views clamp it to the
    /// emulator's real history depth.
    static let scrollTopSentinel = 10_000

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
}
