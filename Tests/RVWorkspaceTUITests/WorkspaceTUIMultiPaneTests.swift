import Foundation
import Testing
@testable import RVWorkspaceTUI

private let multiSummary = WorkspaceTUISummary(
    project: "/tmp/multi", phase: "active", protected: true,
    workspace: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
)
private let multiShell = RuntimeLaunchChoice(
    id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil
)

private func multiState() -> WorkspaceTUIState {
    var state = WorkspaceTUIState(
        lifecycle: .connected, summary: multiSummary, launcher: [multiShell],
        initialRows: 24, initialColumns: 80, mode: .terminal,
        terminal: nil, leasedRuntime: nil, retryAcquire: false,
        shouldExit: false, initialLaunchRequested: false,
        viewSize: nil, presentationRevision: 0
    )
    state.viewSize = .init(rows: 30, columns: 100)
    return state
}

private func prefixed(_ state: WorkspaceTUIState, _ key: Character) -> WorkspaceTUITransition {
    let entered = WorkspaceTUIReducer.reduce(state, .key(.control("b")))
    return WorkspaceTUIReducer.reduce(entered.state, .key(.character(key)))
}

@Suite struct WorkspaceTUIMultiPaneTests {
    @Test func impossibleSplitRefusesBeforeHostLaunch() {
        var state = multiState()
        state.viewSize = .init(rows: 7, columns: 22)
        let result = prefixed(state, "v")
        #expect(result.state.view == state.view)
        #expect(result.effects.isEmpty)
    }

    @Test func splitCreatesFocusedPaneAndQueuesDefaultShell() throws {
        let start = multiState()
        let oldPane = try #require(start.activePaneID)
        let result = prefixed(start, "v")
        let newPane = try #require(result.state.activePaneID)
        #expect(newPane != oldPane)
        #expect(result.state.view.activeTab?.tree.leafCount == 2)
        #expect(result.state.view.panes[newPane]?.lifecycle == .launching)
        #expect(result.effects == [.queueLaunch(
            target: PrefixTarget(pane: newPane, generation: nil), choice: multiShell
        )])
    }

    @Test func splitQueuesOperatorDefaultShellVariant() throws {
        var start = multiState()
        let variant = RuntimeLaunchChoice(
            id: "shell:docs", title: "shell · docs (default)", executable: "/bin/sh",
            arguments: [], hook: nil, resourceProfileID: "docs"
        )
        start.launcher = [multiShell, variant]
        start.defaultShellID = "shell:docs"
        let result = prefixed(start, "v")
        let newPane = try #require(result.state.activePaneID)
        #expect(result.effects == [.queueLaunch(
            target: PrefixTarget(pane: newPane, generation: nil), choice: variant
        )])
    }

    @Test func tabSwitchPreservesFocusAndHiddenRuntimeOutput() throws {
        var state = multiState()
        let first = try #require(state.activePaneID)
        let firstRuntime = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let listed = ListedRuntime(id: firstRuntime, hook: nil, running: true, terminal: true)
        state.terminal = WorkspaceTUIState.AttachedTerminal(
            state: WorkspaceTerminalState(runtime: listed.id, title: "shell", running: true,
                                          lease: .owned, subscribed: true),
            resize: ResizeCoalescer()
        )
        let tab = prefixed(state, "c")
        #expect(tab.state.view.tabs.count == 2)
        let hiddenEvent = WorkspaceTUIReducer.reduce(tab.state, .hostEvents([
            .bytes(runtime: firstRuntime, data: Data("hidden".utf8))
        ]))
        #expect(hiddenEvent.effects == [.feedEmulator(
            binding: PaneBindingKey(pane: first, runtime: firstRuntime, generation: 1),
            data: Data("hidden".utf8)
        )])
        let previous = prefixed(hiddenEvent.state, "p")
        #expect(previous.state.activePaneID == first)
    }

    @Test func closePaneReleasesSubscriptionButDoesNotCancelRuntime() throws {
        var state = multiState()
        let first = try #require(state.activePaneID)
        let runtime = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        state.terminal = WorkspaceTUIState.AttachedTerminal(
            state: WorkspaceTerminalState(runtime: runtime, title: "shell", running: true,
                                          lease: .owned, subscribed: true),
            resize: ResizeCoalescer()
        )
        state.leasedRuntime = runtime
        let split = prefixed(state, "v")
        let back = prefixed(split.state, "h")
        #expect(back.state.activePaneID == first)
        let closed = prefixed(back.state, "x")
        #expect(closed.state.view.panes[first] == nil)
        #expect(closed.effects.contains(.release(runtime: runtime)))
        #expect(closed.effects.contains { if case .cancel = $0 { true } else { false } } == false)
    }
}
