#if os(macOS)
import Foundation
import SwiftTUICLI
import Testing
@testable import RVWorkspaceTUI

/// The pane chrome as SwiftTUI actually draws it: every row the pane's
/// width, the ask in the bottom border, and the title where it belongs.
@MainActor
struct WorkspacePanePanelRenderTests {
    private func render(width: Int, height: Int, title: String, focused: Bool, ask: String?) -> [String] {
        let id = PaneID()
        let placement = PanePlacement(
            id: id, outer: CellRect(x: 0, y: 0, width: width, height: height),
            content: CellRect(x: 1, y: 1, width: width - 2, height: height - 2))
        let terminal = WorkspaceTerminalState(runtime: UUID(), title: title, running: true, lease: .owned)
        let panel = WorkspacePanePanel(
            pane: WorkspacePane(id: id, lifecycle: .running), terminal: terminal, frame: nil,
            placement: placement, focused: focused, recentOutputOnly: false, scrolling: false,
            ask: ask, hasNewOutput: false)
        let snapshot = DefaultRenderer().render(panel, proposal: ProposedSize(width: width, height: height))
        return snapshot.rasterSurface.lines
    }

    @Test func focusedAgentPaneWithAnAsk() {
        let lines = render(width: 50, height: 4, title: "claude", focused: true,
                           ask: "◐ wants out api.stripe.com:443 · ^B R answer")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("╭▸ ⏺ claude ─"))
        #expect(lines[0].hasSuffix("─╮"))
        #expect(lines[3].hasPrefix("╰ ◐ wants out api.stripe.com:443 · ^B R answer ─"))
        #expect(lines[3].hasSuffix("╯"))
        #expect(lines.allSatisfy { WorkspaceCells.width($0) == 50 })
    }

    @Test func unfocusedShellPaneIsAPlainBox() {
        let lines = render(width: 30, height: 3, title: "zsh", focused: false, ask: nil)
        #expect(lines[0] == "╭─ zsh " + String(repeating: "─", count: 22) + "╮")
        #expect(lines[2] == "╰" + String(repeating: "─", count: 28) + "╯")
    }

    @Test func minimumWidthPaneKeepsItsCorners() {
        let lines = render(width: 22, height: 3, title: String(repeating: "x", count: 60), focused: true, ask: nil)
        #expect(lines[0].hasPrefix("╭▸ x"))
        #expect(lines[0].hasSuffix("╮"))
        #expect(WorkspaceCells.width(lines[0]) == 22)
    }
}
#endif
