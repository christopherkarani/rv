import Foundation
import Testing
@testable import RVWorkspaceTUI

@Test func renderPlanOnlyPlacesActiveTabAndZoomedPane() {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let first = TabID(), hidden = TabID()
    let tree = PaneTree.split(SplitID(), .vertical, .half, .leaf(a), .leaf(b))
    let view = WorkspaceView(id: ViewID(), tabs: [
        WorkspaceTab(id: first, tree: tree, focusedPaneID: b),
        WorkspaceTab(id: hidden, tree: .leaf(c), focusedPaneID: c),
    ], activeTabID: first, panes: [
        a: WorkspacePane(id: a), b: WorkspacePane(id: b), c: WorkspacePane(id: c),
    ])
    let plan = WorkspacePaneRenderPlan.make(view: view, columns: 80, rows: 24)
    #expect(plan.state == .ready)
    #expect(plan.visiblePaneIDs == [a, b])
    #expect(plan.dividers.count == 1)
    #expect(plan.placements.map(\.content.width) == [37, 38])
    let zoomed = WorkspaceView(id: view.id, tabs: [
        WorkspaceTab(id: first, tree: tree, focusedPaneID: b, zoomedPaneID: b),
        WorkspaceTab(id: hidden, tree: .leaf(c), focusedPaneID: c),
    ], activeTabID: first, panes: view.panes)
    let zoomPlan = WorkspacePaneRenderPlan.make(view: zoomed, columns: 80, rows: 24)
    #expect(zoomPlan.visiblePaneIDs == [b])
    #expect(zoomPlan.dividers.isEmpty)
    #expect(zoomPlan.placements[0].content.width == 78)
}

@Test func renderPlanRejectsTooSmallViewportWithoutConstructingPanes() {
    let pane = PaneID()
    let tab = WorkspaceTab(id: TabID(), tree: .leaf(pane), focusedPaneID: pane)
    let view = WorkspaceView(id: ViewID(), tabs: [tab], activeTabID: tab.id,
                             panes: [pane: WorkspacePane(id: pane)])
    let tooSmall = WorkspacePaneRenderPlan.make(view: view, columns: 21, rows: 6)
    #expect(tooSmall.state == .tooSmall)
    #expect(tooSmall.visiblePaneIDs.isEmpty)
    #expect(WorkspacePaneRenderPlan.make(view: WorkspaceView(id: ViewID()), columns: 80, rows: 24).state == .empty)
}

@Test func chromeSanitizesUntrustedTitlesAndReportsLifecycle() {
    let pane = PaneID()
    let presentation = WorkspacePane(id: pane, userTitle: "\u{1B}[31mEdit\n界🙂\u{202E}", lifecycle: .running)
    let terminal = WorkspaceTerminalState(runtime: UUID(), title: "shell", running: true, lease: .readOnly)
    #expect(WorkspacePaneChrome.title(presentation, terminal: terminal) == "[31mEdit界🙂")
    #expect(WorkspacePaneChrome.status(presentation, terminal: terminal) == "read only")
    #expect(WorkspacePaneChrome.status(presentation, terminal: nil, recentOutputOnly: true)
            == "recent output only")
    #expect(WorkspacePaneChrome.title(WorkspacePane(id: pane), terminal: terminal) == "shell")
    #expect(WorkspacePaneChrome.status(WorkspacePane(id: pane), terminal: nil) == "new shell")
}

@Test func chromeLifecycleTruthSurvivesStaleReadOnlyLease() {
    let pane = PaneID()
    let stale = WorkspaceTerminalState(runtime: UUID(), title: "shell", running: true, lease: .readOnly)
    #expect(WorkspacePaneChrome.status(WorkspacePane(id: pane, lifecycle: .missing), terminal: stale)
            == "runtime missing")
    #expect(WorkspacePaneChrome.status(WorkspacePane(id: pane, lifecycle: .disconnected), terminal: stale)
            == "disconnected")
    #expect(WorkspacePaneChrome.status(WorkspacePane(id: pane, lifecycle: .exited), terminal: stale)
            == "exited")
    #expect(WorkspacePaneChrome.status(WorkspacePane(id: pane, lifecycle: .running), terminal: stale)
            == "read only")
}

@Test func statusLabelHeaderWordsDoNotRelyOnColorAlone() {
    // Each header colour must pair with a distinct short word (UX-07).
    #expect(WorkspaceStatusLabel.header(connection: .disconnected, terminalNeedsAttention: false, phase: "active", protected: true) == "disconnected")
    #expect(WorkspaceStatusLabel.header(connection: .connected, terminalNeedsAttention: true, phase: "active", protected: true) == "attention")
    #expect(WorkspaceStatusLabel.header(connection: .connected, terminalNeedsAttention: false, phase: "active", protected: true) == "running")
    #expect(WorkspaceStatusLabel.header(connection: .connected, terminalNeedsAttention: false, phase: "idle", protected: false) == "idle")
}

@Test func statusLabelPaneIndicatorPairsGlyphWithWord() {
    #expect(WorkspaceStatusLabel.paneIndicator(focused: true) == "● focused")
    #expect(WorkspaceStatusLabel.paneIndicator(focused: false) == "╭ unfocus")
    #expect(WorkspaceStatusLabel.focus(focused: true) == "focused")
    #expect(WorkspaceStatusLabel.focus(focused: false) == "unfocus")
    // Pane runtime status is already a word; it must stay non-empty for every lifecycle.
    let pane = PaneID()
    for lifecycle in [WorkspacePaneLifecycle.empty, .launching, .attaching, .running, .exited, .launchFailed, .disconnected, .missing] {
        #expect(WorkspacePaneChrome.status(WorkspacePane(id: pane, lifecycle: lifecycle), terminal: nil).isEmpty == false)
    }
}

@Test func statusLabelLeavesTitleCellAtMinimumPaneWidth() {
    // titleWidth includes the leading space, so 2 is one visible title cell.
    let width = PaneTree.leaf(PaneID()).minimumOuterSize.width
    #expect(width == 22)
    for focused in [true, false] {
        let indicator = WorkspaceStatusLabel.paneIndicator(focused: focused)
        let titleWidth = WorkspaceStatusLabel.paneTitleWidth(outerWidth: width, focused: focused)
        let statusWidth = WorkspaceStatusLabel.paneStatusWidth(outerWidth: width)
        #expect(titleWidth >= 2)
        #expect(indicator.count + titleWidth + statusWidth + 1 == width)
    }
}

@Test func terminalCellClipperKeepsGraphemesAndAvoidsHalfWidePaint() {
    let wide = [TerminalCell(text: "界"), TerminalCell(text: "")]
    #expect(TerminalCellClipper.clipped(wide, columns: 1).map(\.text) == [" "])
    #expect(TerminalCellClipper.clipped(wide, columns: 2).map(\.text) == ["界", ""])
    let emoji = [TerminalCell(text: "🙂"), TerminalCell(text: "")]
    #expect(TerminalCellClipper.clipped(emoji, columns: 1).map(\.text) == [" "])
    let combining = [TerminalCell(text: "e\u{301}")]
    #expect(TerminalCellClipper.clipped(combining, columns: 1).map(\.text) == ["e\u{301}"])
}
