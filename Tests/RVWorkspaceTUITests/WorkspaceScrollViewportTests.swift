import Foundation
import Testing
@testable import RVWorkspaceTUI

private func feedLines(_ terminal: SwiftTermAdapter, _ names: [String]) {
    for name in names {
        terminal.feed(Data("\(name)\r\n".utf8))
    }
}

@Test func scrollHistoryExposesLinesAboveLiveViewport() {
    let terminal = SwiftTermAdapter(columns: 20, rows: 4)
    #expect(terminal.historyDescription()
        == TerminalHistoryDescription(linesAbove: 0, alternateScreen: false))
    feedLines(terminal, ["L0", "L1", "L2", "L3", "L4", "L5"])
    let depth = terminal.historyDescription().linesAbove
    #expect(depth == 3)
    #expect(terminal.historyDescription().alternateScreen == false)

    // Oldest retained viewport starts at the first fed line.
    let oldest = terminal.historyFrame(anchor: depth, rows: 4, columns: 20)
    #expect(oldest?.line(0).contains("L0") == true)
    #expect(oldest?.line(3).contains("L3") == true)
    #expect(oldest?.cursor == nil)

    // Anchor 1 ends one line above the live bottom.
    let live = terminal.frame()
    #expect(live.cursor != nil)
    let above = terminal.historyFrame(anchor: 1, rows: 4, columns: 20)
    #expect(above?.line(0).contains("L2") == true)
    #expect(above?.line(3) == live.line(2))
    #expect(above?.cursor == nil)

    // Anchor 0 is the live frame minus the cursor.
    let zero = terminal.historyFrame(anchor: 0, rows: 4, columns: 20)
    #expect(zero?.cursor == nil)
    for row in 0..<4 {
        #expect(zero?.line(row) == live.line(row))
    }
}

@Test func scrollHistoryClampsAnchorToRetainedDepth() {
    let terminal = SwiftTermAdapter(columns: 20, rows: 4)
    feedLines(terminal, ["L0", "L1", "L2", "L3", "L4", "L5"])
    let depth = terminal.historyDescription().linesAbove
    let oldest = terminal.historyFrame(anchor: depth, rows: 4, columns: 20)
    // The scroll-top sentinel (10000) clamps to the oldest retained viewport.
    #expect(terminal.historyFrame(anchor: 10_000, rows: 4, columns: 20) == oldest)
    #expect(oldest?.line(0).contains("L0") == true)
    #expect(terminal.historyFrame(anchor: -5, rows: 4, columns: 20)
        == terminal.historyFrame(anchor: 0, rows: 4, columns: 20))
}

@Test func scrollHistoryEmptyOnAlternateScreen() {
    let terminal = SwiftTermAdapter(columns: 20, rows: 4)
    feedLines(terminal, ["L0", "L1", "L2", "L3", "L4", "L5"])
    #expect(terminal.historyDescription().linesAbove > 0)
    terminal.feed(Data("\u{1B}[?1049h".utf8))
    #expect(terminal.historyDescription().alternateScreen)
    #expect(terminal.historyDescription().linesAbove == 0)
    #expect(terminal.historyFrame(anchor: 1, rows: 4, columns: 20) == nil)
    terminal.feed(Data("\u{1B}[?1049l".utf8))
    #expect(terminal.historyDescription().alternateScreen == false)
    #expect(terminal.historyDescription().linesAbove > 0)
}

@Test func scrollHistoryStaysBoundedPastScrollbackCap() {
    let terminal = SwiftTermAdapter(columns: 40, rows: 8)
    var payload = Data()
    for index in 0..<2_000 {
        payload.append(Data("line-\(index)\r\n".utf8))
    }
    terminal.feed(payload)
    let depth = terminal.historyDescription().linesAbove
    #expect(depth > 0)
    #expect(depth <= TerminalScrollback.lines)
    let oldest = terminal.historyFrame(anchor: depth, rows: 8, columns: 40)
    #expect(oldest?.line(0).contains("line-0") == false)
    #expect(oldest?.cursor == nil)
}

@Test func scrollHistoryDefaultsReportNoHistory() {
    let emulator = RecordingEmulator(columns: 80, rows: 24)
    #expect(emulator.historyDescription()
        == TerminalHistoryDescription(linesAbove: 0, alternateScreen: false))
    #expect(emulator.historyFrame(anchor: 5, rows: 24, columns: 80) == nil)
}

@Test func renderPlanFallsBackToFocusedPaneWhenLayoutTooSmall() {
    let a = PaneID(), b = PaneID()
    let tree = PaneTree.split(SplitID(), .vertical, .half, .leaf(a), .leaf(b))
    let tab = WorkspaceTab(id: TabID(), tree: tree, focusedPaneID: b)
    let view = WorkspaceView(
        id: ViewID(), tabs: [tab], activeTabID: tab.id,
        panes: [a: WorkspacePane(id: a), b: WorkspacePane(id: b)]
    )
    let full = WorkspacePaneRenderPlan.make(view: view, columns: 80, rows: 24)
    #expect(full.state == .ready)
    #expect(full.focusedFallback == false)
    #expect(full.visiblePaneIDs == [a, b])
    // A vertical two-pane layout needs 45 columns; 30 fits one pane only.
    let fallback = WorkspacePaneRenderPlan.make(view: view, columns: 30, rows: 10)
    #expect(fallback.state == .ready)
    #expect(fallback.focusedFallback)
    #expect(fallback.visiblePaneIDs == [b])
}

@Test func renderPlanStaysTooSmallWhenOnePaneCannotFit() {
    let a = PaneID(), b = PaneID()
    let tree = PaneTree.split(SplitID(), .vertical, .half, .leaf(a), .leaf(b))
    let tab = WorkspaceTab(id: TabID(), tree: tree, focusedPaneID: b)
    let view = WorkspaceView(
        id: ViewID(), tabs: [tab], activeTabID: tab.id,
        panes: [a: WorkspacePane(id: a), b: WorkspacePane(id: b)]
    )
    let tiny = WorkspacePaneRenderPlan.make(view: view, columns: 1, rows: 1)
    #expect(tiny.state == .tooSmall)
    #expect(tiny.focusedFallback == false)
    #expect(tiny.visiblePaneIDs.isEmpty)
}
