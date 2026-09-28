import Foundation
import Testing
@testable import RVWorkspaceTUI

private let modeTarget = PrefixTarget(pane: PaneID(), generation: nil)

@Test func overlayPrefixBindingsOpenModesDirectly() {
    #expect(CommandPrefix.route(.character("r"), mode: .prefix(modeTarget), launcher: [])
        == (.resize, .enterResize))
    #expect(CommandPrefix.route(.character("["), mode: .prefix(modeTarget), launcher: [])
        == (.scroll(pane: modeTarget.pane), .enterScroll))
    #expect(CommandPrefix.route(.character("w"), mode: .prefix(modeTarget), launcher: [])
        == (.navigator(index: 0), .enterNavigator))
    #expect(CommandPrefix.route(.character("!"), mode: .prefix(modeTarget), launcher: [])
        == (.confirmCancel(pane: modeTarget.pane), .enterConfirmCancel))
    #expect(CommandPrefix.route(.character("v"), mode: .prefix(modeTarget), launcher: []).1 == .split(.vertical))
    #expect(CommandPrefix.route(.character("?"), mode: .prefix(modeTarget), launcher: []) == (.help, .help))
    #expect(CommandPrefix.route(.control("b"), mode: .prefix(modeTarget), launcher: []).1 == .send(Data([0x02])))
    #expect(CommandPrefix.route(.escape, mode: .prefix(modeTarget), launcher: []) == (.terminal, nil))
}

@Test func resizeOverlayStepsWithoutFallthrough() {
    #expect(CommandPrefix.route(.character("h"), mode: .resize, launcher: [])
        == (.resize, .resizeStep(axis: .vertical, cells: -1)))
    #expect(CommandPrefix.route(.character("l"), mode: .resize, launcher: [])
        == (.resize, .resizeStep(axis: .vertical, cells: 1)))
    #expect(CommandPrefix.route(.character("k"), mode: .resize, launcher: [])
        == (.resize, .resizeStep(axis: .horizontal, cells: -1)))
    #expect(CommandPrefix.route(.character("j"), mode: .resize, launcher: [])
        == (.resize, .resizeStep(axis: .horizontal, cells: 1)))
    #expect(CommandPrefix.route(.enter, mode: .resize, launcher: []) == (.terminal, .finishResize))
    #expect(CommandPrefix.route(.escape, mode: .resize, launcher: []) == (.terminal, .finishResize))
    #expect(CommandPrefix.route(.character("q"), mode: .resize, launcher: []) == (.resize, nil))
    #expect(CommandPrefix.route(.arrow(.up), mode: .resize, launcher: []) == (.resize, nil))
}

@Test func scrollOverlayMovesAwayFromLiveAndExits() {
    let mode = CommandMode.scroll(pane: modeTarget.pane)
    #expect(CommandPrefix.route(.character("j"), mode: mode, launcher: []) == (mode, .scrollDelta(lines: -1)))
    #expect(CommandPrefix.route(.arrow(.down), mode: mode, launcher: []) == (mode, .scrollDelta(lines: -1)))
    #expect(CommandPrefix.route(.character("k"), mode: mode, launcher: []) == (mode, .scrollDelta(lines: 1)))
    #expect(CommandPrefix.route(.arrow(.up), mode: mode, launcher: []) == (mode, .scrollDelta(lines: 1)))
    #expect(CommandPrefix.route(.pageDown, mode: mode, launcher: [])
        == (mode, .scrollDelta(lines: -CommandPrefix.scrollPageLines)))
    #expect(CommandPrefix.route(.pageUp, mode: mode, launcher: [])
        == (mode, .scrollDelta(lines: CommandPrefix.scrollPageLines)))
    #expect(CommandPrefix.route(.character("g"), mode: mode, launcher: []) == (mode, .scrollTop))
    #expect(CommandPrefix.route(.character("G"), mode: mode, launcher: []) == (mode, .scrollBottom))
    #expect(CommandPrefix.route(.character("q"), mode: mode, launcher: []) == (.terminal, .exitScroll))
    #expect(CommandPrefix.route(.escape, mode: mode, launcher: []) == (.terminal, .exitScroll))
    #expect(CommandPrefix.route(.character("x"), mode: mode, launcher: []) == (mode, nil))
}

@Test func navigatorOverlayTracksIndexAndActivates() {
    #expect(CommandPrefix.route(.character("j"), mode: .navigator(index: 0), launcher: [])
        == (.navigator(index: 1), .navigatorMove(delta: 1)))
    #expect(CommandPrefix.route(.arrow(.down), mode: .navigator(index: 1), launcher: [])
        == (.navigator(index: 2), .navigatorMove(delta: 1)))
    #expect(CommandPrefix.route(.character("k"), mode: .navigator(index: 2), launcher: [])
        == (.navigator(index: 1), .navigatorMove(delta: -1)))
    #expect(CommandPrefix.route(.arrow(.up), mode: .navigator(index: 0), launcher: [])
        == (.navigator(index: -1), .navigatorMove(delta: -1)))
    #expect(CommandPrefix.route(.enter, mode: .navigator(index: 3), launcher: [])
        == (.terminal, .navigatorActivate))
    #expect(CommandPrefix.route(.character("w"), mode: .navigator(index: 3), launcher: [])
        == (.terminal, .exitNavigator))
    #expect(CommandPrefix.route(.escape, mode: .navigator(index: 3), launcher: [])
        == (.terminal, .exitNavigator))
    #expect(CommandPrefix.route(.character("q"), mode: .navigator(index: 3), launcher: [])
        == (.navigator(index: 3), nil))
}

@Test func confirmCancelOverlayConfirmsOrDismisses() {
    let mode = CommandMode.confirmCancel(pane: modeTarget.pane)
    #expect(CommandPrefix.route(.enter, mode: mode, launcher: []) == (.terminal, .confirmCancel))
    #expect(CommandPrefix.route(.character("y"), mode: mode, launcher: []) == (.terminal, .confirmCancel))
    #expect(CommandPrefix.route(.escape, mode: mode, launcher: []) == (.terminal, .dismissConfirm))
    #expect(CommandPrefix.route(.character("n"), mode: mode, launcher: []) == (.terminal, .dismissConfirm))
    #expect(CommandPrefix.route(.character("j"), mode: mode, launcher: []) == (mode, nil))
}

@Test func terminalEnterAndHelpBehaviorUnchanged() {
    #expect(CommandPrefix.route(.enter, mode: .terminal, launcher: []) == (.terminal, .sendKey(.enter)))
    #expect(CommandPrefix.route(.character("r"), mode: .help, launcher: []) == (.terminal, .dismissOverlay))
    let entered = CommandPrefix.route(.control("b"), mode: .terminal, launcher: [], target: modeTarget)
    #expect(entered == (.prefix(modeTarget), nil))
}

@Test func launcherEnterOffersRelaunch() {
    #expect(CommandPrefix.route(.enter, mode: .launcher, launcher: []) == (.terminal, .relaunchShell))
}

// MARK: - Reducer mode behavior

private let modesWorkspace = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let modesSummary = WorkspaceTUISummary(
    project: "/tmp/project", phase: "active", protected: true, workspace: modesWorkspace
)
private let modesShell = RuntimeLaunchChoice(
    id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil
)
private let modesRuntimeA = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
private let modesRuntimeB = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!

private func modesState(
    view: WorkspaceView? = nil,
    lifecycle: WorkspaceTUILifecycle = .connected,
    viewSize: WorkspaceTUIState.ViewSize? = .init(rows: 40, columns: 100)
) -> WorkspaceTUIState {
    let pane = PaneID()
    let tab = TabID()
    var state = WorkspaceTUIState(
        lifecycle: .neverConnected,
        summary: modesSummary,
        launcher: [modesShell],
        initialRows: 24,
        initialColumns: 80,
        mode: .terminal,
        terminal: nil,
        leasedRuntime: nil,
        retryAcquire: false,
        shouldExit: false,
        initialLaunchRequested: true,
        viewSize: viewSize,
        presentationRevision: 1,
        paneID: pane,
        tabID: tab
    )
    if let view { state.view = view }
    state.lifecycle = lifecycle
    return state
}

private func modesAttached(
    runtime: UUID = modesRuntimeA,
    running: Bool = true,
    lease: InputLease = .owned
) -> WorkspaceTUIState.AttachedTerminal {
    var resize = ResizeCoalescer()
    resize.recordLaunch(rows: 24, columns: 80)
    return WorkspaceTUIState.AttachedTerminal(
        state: WorkspaceTerminalState(
            runtime: runtime, title: "shell", running: running,
            lease: lease, subscribed: true
        ),
        resize: resize
    )
}

private func modesPress(_ state: WorkspaceTUIState, _ keys: TUIKey...) -> WorkspaceTUITransition {
    var current = state
    var last = WorkspaceTUITransition(state: state, effects: [])
    for key in keys {
        last = WorkspaceTUIReducer.reduce(current, .key(key))
        current = last.state
    }
    return last
}

private func modesSplit() -> WorkspaceTUIState {
    var state = modesState()
    let rect = CellRect(x: 0, y: 0, width: 100, height: 40)
    state.view = state.view.splittingFocusedPane(axis: .vertical, in: rect)!
    return state
}

@Suite struct WorkspaceTUIModeReducerTests {
    @Test func resizeEnterRequiresAdjustableDivider() {
        let transition = modesPress(modesState(), .control("b"), .character("r"))
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.feedback == "Nothing to resize")
    }

    @Test func resizeStepsMoveDividerOneCellLayoutOnly() {
        let before = modesSplit()
        let rect = CellRect(x: 0, y: 0, width: 100, height: 40)
        let firstBefore = PaneGeometry.solve(before.view.activeTab!.tree, in: rect)!.dividers[0].rect.x
        var transition = modesPress(before, .control("b"), .character("r"))
        #expect(transition.state.mode == .resize)
        transition = modesPress(transition.state, .character("l"))
        let firstAfter = PaneGeometry.solve(transition.state.view.activeTab!.tree, in: rect)!.dividers[0].rect.x
        #expect(firstAfter == firstBefore + 1)
        #expect(transition.effects == [])
        #expect(transition.state.mode == .resize)
        transition = modesPress(transition.state, .character("h"))
        let firstRestored = PaneGeometry.solve(transition.state.view.activeTab!.tree, in: rect)!.dividers[0].rect.x
        #expect(firstRestored == firstBefore)
        transition = modesPress(transition.state, .enter)
        #expect(transition.state.mode == .terminal)
        transition = modesPress(modesSplit(), .control("b"), .character("r"))
        transition = modesPress(transition.state, .escape)
        #expect(transition.state.mode == .terminal)
    }

    @Test func resizeStepClampsAtMinimum() {
        var state = modesState(viewSize: .init(rows: 7, columns: 45))
        state.view = state.view.splittingFocusedPane(
            axis: .vertical, in: CellRect(x: 0, y: 0, width: 45, height: 7)
        )!
        var transition = modesPress(state, .control("b"), .character("r"))
        #expect(transition.state.mode == .resize)
        transition = modesPress(transition.state, .character("h"))
        #expect(transition.state.feedback == "At minimum size")
        #expect(transition.state.view == state.view)
    }

    @Test func scrollAnchorMovesTowardAndAwayFromLive() {
        var state = modesState()
        state.terminal = modesAttached()
        var transition = modesPress(state, .control("b"), .character("["))
        guard case .scroll = transition.state.mode else {
            Issue.record("expected scroll mode")
            return
        }
        let pane = state.activePaneID!
        #expect(transition.state.scrollAnchors[pane] == 0)
        transition = modesPress(transition.state, .character("k"))
        #expect(transition.state.scrollAnchors[pane] == 1)
        transition = modesPress(transition.state, .character("j"))
        #expect(transition.state.scrollAnchors[pane] == 0)
        transition = modesPress(transition.state, .character("j"))
        #expect(transition.state.scrollAnchors[pane] == 0)
        transition = modesPress(transition.state, .character("g"))
        #expect(transition.state.scrollAnchors[pane] == WorkspaceTUIReducer.scrollTopSentinel)
        transition = modesPress(transition.state, .character("G"))
        #expect(transition.state.scrollAnchors[pane] == 0)
        transition = modesPress(transition.state, .character("q"))
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.scrollAnchors[pane] == 0)
    }

    @Test func scrollPageUsesViewportHeight() {
        var state = modesState()
        state.terminal = modesAttached()
        var transition = modesPress(state, .control("b"), .character("["))
        let pane = state.activePaneID!
        transition = modesPress(transition.state, .pageUp)
        // 40-row viewport, one-cell border top and bottom: 38 content rows.
        #expect(transition.state.scrollAnchors[pane] == 38)
        transition = modesPress(transition.state, .pageDown)
        #expect(transition.state.scrollAnchors[pane] == 0)
    }

    @Test func scrollEnterRequiresBoundPane() {
        let transition = modesPress(modesState(), .control("b"), .character("["))
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.feedback == "Nothing to scroll")
    }

    @Test func scrollCancelsWhenPaneRebinds() {
        var state = modesState()
        state.terminal = modesAttached()
        var transition = modesPress(state, .control("b"), .character("["))
        guard case .scroll = transition.state.mode else {
            Issue.record("expected scroll mode")
            return
        }
        transition.state.terminal = modesAttached(runtime: modesRuntimeB)
        transition = modesPress(transition.state, .character("k"))
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.feedback == "Pane changed; scroll cancelled")
    }

    @Test func navigatorListsTabsThenUnplacedRuntimes() {
        var state = modesState()
        state.terminal = modesAttached()
        state.leasedBindings = [state.activeBindingKey!]
        state.knownRuntimes = [
            ListedRuntime(id: modesRuntimeB, hook: nil, running: true, terminal: true),
            ListedRuntime(id: modesRuntimeA, hook: nil, running: true, terminal: true),
        ]
        let transition = modesPress(state, .control("b"), .character("w"))
        guard case .navigator(let index) = transition.state.mode, index == 0 else {
            Issue.record("expected navigator at 0")
            return
        }
        #expect(transition.effects == [.refreshInventory])
        let items = transition.state.navigatorItems
        // Focused pane owns input, so release comes first, then the tab,
        // then the one unplaced runtime.
        #expect(items.count == 3)
        #expect(items[0] == .releaseInput)
        guard case .tab = items[1] else {
            Issue.record("expected tab item")
            return
        }
        #expect(items[2] == .runtime(id: modesRuntimeB, label: "runtime 00000000"))
    }

    @Test func navigatorMoveClampsAndActivateSwitchesTab() {
        var state = modesSplit()
        state.knownRuntimes = []
        var transition = modesPress(state, .control("b"), .character("w"))
        transition = modesPress(transition.state, .character("k"))
        guard case .navigator(let clamped) = transition.state.mode else {
            Issue.record("expected navigator mode")
            return
        }
        #expect(clamped == 0)
        transition = modesPress(transition.state, .character("j"))
        transition = modesPress(transition.state, .character("j"))
        guard case .navigator(let end) = transition.state.mode else {
            Issue.record("expected navigator mode")
            return
        }
        #expect(end == transition.state.navigatorItems.count - 1)
        transition = modesPress(transition.state, .escape)
        #expect(transition.state.mode == .terminal)
    }

    @Test func navigatorActivateAttachesUnplacedRuntime() {
        var state = modesState()
        state.knownRuntimes = [
            ListedRuntime(id: modesRuntimeB, hook: nil, running: true, terminal: true, rows: 24, columns: 80),
        ]
        var transition = modesPress(state, .control("b"), .character("w"))
        // Items: [tab, runtime]. Move to the runtime and activate.
        transition = modesPress(transition.state, .character("j"))
        transition = modesPress(transition.state, .enter)
        #expect(transition.state.mode == .terminal)
        let pane = state.activePaneID!
        let binding = transition.state.bindingKey(for: pane)!
        #expect(binding.runtime == modesRuntimeB)
        #expect(transition.effects.contains(.createEmulator(binding: binding, rows: 24, columns: 80)))
        #expect(transition.effects.contains(.attach(binding: binding, context: .launch)))
    }

    @Test func navigatorActivateAcquireEmitsAcquireOnly() {
        var state = modesState()
        state.terminal = modesAttached(lease: .readOnly)
        var transition = modesPress(state, .control("b"), .character("w"))
        #expect(transition.state.navigatorItems.first == .acquireInput)
        transition = modesPress(transition.state, .enter)
        let binding = state.bindingKey(for: state.activePaneID!)!
        #expect(transition.effects == [.acquire(binding: binding)])
        #expect(transition.state.mode == .terminal)
    }

    @Test func inventoryRefreshRebuildsNavigatorPreservingSelection() {
        var state = modesState()
        state.knownRuntimes = [
            ListedRuntime(id: modesRuntimeB, hook: nil, running: true, terminal: true),
        ]
        var transition = modesPress(state, .control("b"), .character("w"))
        transition = modesPress(transition.state, .character("j"))
        guard case .navigator(1) = transition.state.mode else {
            Issue.record("expected navigator at 1")
            return
        }
        transition = WorkspaceTUIReducer.reduce(
            transition.state,
            .inventoryRefreshed(terminals: [
                ListedRuntime(id: modesRuntimeB, hook: nil, running: true, terminal: true),
                ListedRuntime(id: modesRuntimeA, hook: nil, running: true, terminal: true),
            ])
        )
        guard case .navigator(let index) = transition.state.mode else {
            Issue.record("expected navigator mode")
            return
        }
        #expect(transition.state.navigatorItems[index] == .runtime(id: modesRuntimeB, label: "runtime 00000000"))
    }

    @Test func confirmCancelRequiresBindingAndConfirmsExplicitly() {
        var refused = modesPress(modesState(), .control("b"), .character("!"))
        #expect(refused.state.mode == .terminal)
        #expect(refused.state.feedback == "No runtime to cancel")

        var state = modesState()
        state.terminal = modesAttached()
        var transition = modesPress(state, .control("b"), .character("!"))
        guard case .confirmCancel = transition.state.mode else {
            Issue.record("expected confirm mode")
            return
        }
        transition = modesPress(transition.state, .character("y"))
        #expect(transition.state.mode == .terminal)
        #expect(transition.effects == [.cancel(runtime: modesRuntimeA)])

        transition = modesPress(state, .control("b"), .character("!"))
        transition = modesPress(transition.state, .escape)
        #expect(transition.state.mode == .terminal)
        #expect(transition.effects == [])
    }

    @Test func enterRelaunchesShellOnDeadPane() {
        var exited = modesState()
        exited.terminal = modesAttached(running: false)
        exited.terminal?.state.exitStatus = 1
        exited.updatePane(exited.activePaneID!) { $0.lifecycle = .exited }
        var transition = modesPress(exited, .enter)
        let target = PrefixTarget(
            pane: exited.activePaneID!, generation: exited.activeBindingKey?.generation
        )
        #expect(transition.effects == [.queueLaunch(target: target, choice: modesShell)])
        #expect(transition.state.view.panes[exited.activePaneID!]!.lifecycle == .launching)

        var empty = modesState()
        transition = modesPress(empty, .enter)
        let emptyTarget = PrefixTarget(pane: empty.activePaneID!, generation: nil)
        #expect(transition.effects == [.queueLaunch(target: emptyTarget, choice: modesShell)])

        var launcher = modesState()
        launcher.terminal = modesAttached(running: false)
        launcher.updatePane(launcher.activePaneID!) { $0.lifecycle = .exited }
        launcher.mode = .launcher
        transition = modesPress(launcher, .enter)
        let launcherTarget = PrefixTarget(
            pane: launcher.activePaneID!, generation: launcher.activeBindingKey?.generation
        )
        #expect(transition.effects == [.queueLaunch(target: launcherTarget, choice: modesShell)])
        #expect(transition.state.mode == .terminal)
    }

    @Test func enterOnRunningPaneStillSendsKey() {
        var state = modesState()
        state.terminal = modesAttached()
        let binding = state.activeBindingKey!
        state.leasedBindings = [binding]
        let transition = modesPress(state, .enter)
        #expect(transition.effects == [.queueKey(binding: binding, key: .enter)])
    }

    @Test func prefixCannotStartInsideOverlay() {
        var state = modesSplit()
        var transition = modesPress(state, .control("b"), .character("r"))
        #expect(transition.state.mode == .resize)
        transition = modesPress(transition.state, .control("b"))
        #expect(transition.state.mode == .resize)
        #expect(transition.effects == [])
    }

    @Test func releaseInputEffectReleasesLeaseOnly() {
        var state = modesState()
        state.terminal = modesAttached()
        let binding = state.activeBindingKey!
        state.leasedBindings = [binding]
        var transition = modesPress(state, .control("b"), .character("w"))
        #expect(transition.state.navigatorItems.first == .releaseInput)
        transition = modesPress(transition.state, .enter)
        #expect(transition.effects == [.releaseInput(binding: binding)])
    }

    @Test func disconnectStashesLeaseAndSchedulesReconnect() throws {
        var state = modesState()
        state.terminal = modesAttached()
        let binding = state.activeBindingKey!
        state.leasedBindings = [binding]
        var transition = WorkspaceTUIReducer.reduce(state, .hostDisconnected)
        #expect(transition.state.lifecycle == .disconnected)
        #expect(transition.state.preDisconnectLeases == [binding])
        #expect(transition.state.leasedBindings == [])
        let now = Date()
        transition = WorkspaceTUIReducer.reduce(transition.state, .tick(now: now))
        #expect(transition.effects == [])
        let firesAt = try #require(transition.state.reconnectFiresAt)
        #expect(firesAt == now.addingTimeInterval(WorkspaceTUIReducer.reconnectDelay(attempt: 0)))
        transition = WorkspaceTUIReducer.reduce(transition.state, .tick(now: firesAt))
        #expect(transition.effects == [.reconnectQuery])
        #expect(transition.state.reconnectInflight == true)
        #expect(transition.state.reconnectAttempt == 1)
    }

    @Test func reconnectBackoffGivesUpAfterMaxAttempts() {
        var state = modesState()
        state.lifecycle = .disconnected
        state.reconnectAttempt = WorkspaceTUIReducer.maxReconnectAttempts
        state.reconnectInflight = true
        var transition = WorkspaceTUIReducer.reduce(state, .reconnectFailed(error: .disconnected))
        #expect(transition.state.feedback == "Workspace unreachable — output preserved")
        #expect(transition.state.reconnectFiresAt == nil)
        transition = WorkspaceTUIReducer.reduce(transition.state, .tick(now: Date()))
        #expect(transition.effects == [])
        transition = WorkspaceTUIReducer.reduce(transition.state, .key(.enter))
        #expect(transition.state.reconnectAttempt == 0)
        #expect(transition.state.feedback == "Reconnecting…")
    }

    @Test func incompatibleHostStopsReconnecting() {
        var state = modesState()
        state.lifecycle = .disconnected
        state.reconnectInflight = true
        let transition = WorkspaceTUIReducer.reduce(state, .reconnectFailed(error: .incompatibleHost))
        #expect(transition.state.feedback == "Incompatible workspace host — close the workspace and retry")
        #expect(transition.state.reconnectFiresAt == nil)
        #expect(transition.state.reconnectInflight == false)
    }

    @Test func reconnectSuccessReattachesAndRestoresLease() {
        var state = modesState()
        state.terminal = modesAttached()
        let binding = state.activeBindingKey!
        state.leasedBindings = [binding]
        var transition = WorkspaceTUIReducer.reduce(state, .hostDisconnected)
        #expect(transition.state.view.panes[state.activePaneID!]!.lifecycle == .disconnected)
        transition = WorkspaceTUIReducer.reduce(transition.state, .reconnectSucceeded(terminals: [
            ListedRuntime(id: modesRuntimeA, hook: nil, running: true, terminal: true),
        ]))
        #expect(transition.state.lifecycle == .connected)
        #expect(transition.effects == [.attach(binding: binding, context: .reconnect), .restartEvents])
        #expect(transition.state.view.panes[state.activePaneID!]!.lifecycle == .attaching)
        #expect(transition.state.preDisconnectLeases == [])
    }

    @Test func reconnectMarksMissingAndClearsAmbiguousLaunches() {
        var state = modesState()
        state.terminal = modesAttached()
        state.leasedBindings = [state.activeBindingKey!]
        var transition = WorkspaceTUIReducer.reduce(state, .hostDisconnected)
        transition = WorkspaceTUIReducer.reduce(transition.state, .reconnectSucceeded(terminals: []))
        #expect(transition.state.view.panes[state.activePaneID!]!.lifecycle == .missing)
        #expect(transition.effects == [.restartEvents])

        var launching = modesState()
        launching.updatePane(launching.activePaneID!) { $0.lifecycle = .launching }
        launching.lifecycle = .disconnected
        transition = WorkspaceTUIReducer.reduce(launching, .reconnectSucceeded(terminals: []))
        #expect(transition.state.view.panes[launching.activePaneID!]!.lifecycle == .empty)
        #expect(transition.effects == [.restartEvents])
    }

    @Test func reconnectObservesUnleasedPanes() {
        var state = modesState()
        state.terminal = modesAttached(lease: .readOnly)
        var transition = WorkspaceTUIReducer.reduce(state, .hostDisconnected)
        let binding = state.activeBindingKey!
        transition = WorkspaceTUIReducer.reduce(transition.state, .reconnectSucceeded(terminals: [
            ListedRuntime(id: modesRuntimeA, hook: nil, running: true, terminal: true),
        ]))
        #expect(transition.effects == [.observe(binding: binding, context: .reconnect), .restartEvents])
    }

    @Test func reconnectAttachFailureMarksPaneMissing() {
        var state = modesState()
        state.terminal = modesAttached()
        let binding = state.activeBindingKey!
        let transition = WorkspaceTUIReducer.reduce(
            state, .attachCompleted(binding: binding, context: .reconnect, outcome: .unavailable)
        )
        #expect(transition.state.view.panes[state.activePaneID!]!.lifecycle == .missing)
    }

    @Test func emptyViewAcceptsTargetlessPrefix() {
        var state = modesState()
        state.view = WorkspaceView(id: state.view.id)
        #expect(state.activePaneID == nil)
        var transition = modesPress(state, .control("b"))
        #expect(transition.state.mode == .prefix(nil))
        transition = modesPress(transition.state, .character("c"))
        #expect(transition.state.view.tabs.count == 1)
        #expect(transition.effects.count == 1)
        guard case .queueLaunch = transition.effects[0] else {
            Issue.record("expected a launch for the new tab")
            return
        }
    }

    @Test func emptyViewDetachesAndReportsUnavailablePaneCommands() {
        var state = modesState()
        state.view = WorkspaceView(id: state.view.id)
        var transition = modesPress(state, .control("b"), .character("q"))
        #expect(transition.state.shouldExit == true)

        transition = modesPress(state, .control("b"), .character("["))
        #expect(transition.state.mode == .terminal)
        #expect(transition.state.feedback == "Unknown Ctrl-B command")

        transition = modesPress(state, .control("b"), .character("!"))
        #expect(transition.state.feedback == "Unknown Ctrl-B command")
    }

    @Test func emptyViewLauncherSelectionCreatesATab() {
        var state = modesState()
        state.view = WorkspaceView(id: state.view.id)
        state.mode = .launcher
        let transition = modesPress(state, .character("1"))
        #expect(transition.state.view.tabs.count == 1)
        guard case .queueLaunch = transition.effects[0] else {
            Issue.record("expected a launch for the new tab")
            return
        }
    }

    @Test func navigatorRuntimeActivationWithoutPaneAsksForATab() {
        var state = modesState()
        state.view = WorkspaceView(id: state.view.id)
        state.knownRuntimes = [
            ListedRuntime(id: modesRuntimeB, hook: nil, running: true, terminal: true),
        ]
        var transition = modesPress(state, .control("b"), .character("w"))
        guard case .navigator = transition.state.mode else {
            Issue.record("expected navigator mode")
            return
        }
        transition = modesPress(transition.state, .enter)
        #expect(transition.state.feedback == "Open a tab first (Ctrl-B c)")
    }

    @Test func runCommandSubmitReplacesLivePane() {
        var state = modesState()
        state.terminal = modesAttached()
        state.mode = .runCommand(input: "/bin/echo hi", error: nil)
        let target = PrefixTarget(
            pane: state.activePaneID!, generation: state.activeBindingKey?.generation
        )
        var transition = modesPress(state, .enter)
        guard case .resolveRunCommand = transition.effects.first else {
            Issue.record("expected run-command resolution, got \(transition.effects)")
            return
        }
        transition = WorkspaceTUIReducer.reduce(
            transition.state,
            .runCommandResolved(target: target, choice: modesShell)
        )
        #expect(transition.state.mode == .terminal)
        #expect(transition.effects == [.queueLaunch(target: target, choice: modesShell)])
        // The launch gate admits the replacement; the old output stays
        // until the new subscription succeeds.
        transition = WorkspaceTUIReducer.reduce(
            transition.state, .launchDue(target: target, choice: modesShell)
        )
        guard case .launchQuery = transition.effects.first else {
            Issue.record("expected a replacement launch query, got \(transition.effects)")
            return
        }
    }

    @Test func replacementDoubleSubmitDropsSecondWhilePending() {
        var state = modesState()
        state.terminal = modesAttached()
        let pane = state.activePaneID!
        let binding = state.activeBindingKey!
        state.pendingLaunches[pane] = WorkspaceTUIState.PendingLaunch(
            binding: PaneBindingKey(pane: pane, runtime: modesRuntimeB, generation: 2),
            terminal: modesAttached(runtime: modesRuntimeB)
        )
        let target = PrefixTarget(pane: pane, generation: binding.generation)
        let transition = WorkspaceTUIReducer.reduce(
            state, .launchDue(target: target, choice: modesShell)
        )
        #expect(transition.effects == [])
    }

    @Test func launchSuccessWhileRunningGoesPending() {
        var state = modesState()
        state.terminal = modesAttached()
        let pane = state.activePaneID!
        let target = PrefixTarget(
            pane: pane, generation: state.activeBindingKey?.generation
        )
        let transition = WorkspaceTUIReducer.reduce(
            state,
            .launchQuerySucceeded(
                target: target, choice: modesShell,
                runtime: ListedRuntime(id: modesRuntimeB, hook: nil, running: true, terminal: true),
                rows: 24, columns: 80
            )
        )
        // Old terminal untouched; the replacement waits for its attach.
        #expect(transition.state.terminals[pane]?.state.runtime == modesRuntimeA)
        #expect(transition.state.pendingLaunches[pane]?.binding.runtime == modesRuntimeB)
        guard case .attach = transition.effects.first else {
            Issue.record("expected a replacement attach, got \(transition.effects)")
            return
        }
    }

    @Test func staleLaunchSuccessAfterRebindDropped() {
        var state = modesState()
        state.terminal = modesAttached()
        let pane = state.activePaneID!
        state.terminal = modesAttached(runtime: modesRuntimeB)
        let staleTarget = PrefixTarget(pane: pane, generation: 1)
        let transition = WorkspaceTUIReducer.reduce(
            state,
            .launchQuerySucceeded(
                target: staleTarget, choice: modesShell,
                runtime: ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true),
                rows: 24, columns: 80
            )
        )
        #expect(transition.effects == [])
        #expect(transition.state.pendingLaunches[pane] == nil)
    }

    @Test func windowNoticeResizesObserverEmulatorOnly() {
        var owned = modesState()
        owned.terminal = modesAttached()
        let ownedBinding = owned.activeBindingKey!
        owned.leasedBindings = [ownedBinding]
        let ownerTransition = WorkspaceTUIReducer.reduce(
            owned, .hostEvents([.window(runtime: modesRuntimeA, rows: 17, columns: 53)])
        )
        #expect(ownerTransition.effects == [])

        var observed = modesState()
        observed.terminal = modesAttached(lease: .readOnly)
        let observerTransition = WorkspaceTUIReducer.reduce(
            observed, .hostEvents([.window(runtime: modesRuntimeA, rows: 17, columns: 53)])
        )
        let observerBinding = observed.activeBindingKey!
        #expect(observerTransition.effects == [.resizeEmulator(binding: observerBinding, rows: 17, columns: 53)])
    }
}
