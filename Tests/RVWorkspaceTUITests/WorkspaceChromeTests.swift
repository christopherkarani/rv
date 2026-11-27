import Foundation
import Testing
@testable import RVWorkspaceTUI

/// L4: the shell's chrome in rv's voice. Colour only for decisions, and
/// every coloured state still carries a word (UX-07).
struct WorkspaceChromeTests {
    private func header(
        connection: ConnectionState = .connected, attention: Bool = false,
        phase: String = "active", protected: Bool = true, panes: Int = 2, agents: Int = 0, pending: Int = 0
    ) -> WorkspaceHeader {
        WorkspaceHeader.make(project: "/Users/me/code/app", connection: connection,
                             terminalNeedsAttention: attention, phase: phase, protected: protected,
                             panes: panes, agents: agents, pending: pending)
    }

    // MARK: - header

    @Test func healthyHeaderIsOneQuietLine() {
        let healthy = header(agents: 2)
        #expect(healthy.name == "app")
        #expect(healthy.words == " · sealed · 2 agents")
        #expect(healthy.edge == WorkspaceToned(text: "✓ quiet", tone: .ok))
        #expect(header(panes: 1).words == " · sealed · 1 pane")
    }

    @Test func rightEdgeShowsTheMostUrgentStateInWords() {
        #expect(header(connection: .disconnected, pending: 2).edge == WorkspaceToned(text: "✕ disconnected", tone: .stopped))
        #expect(header(attention: true, pending: 1).edge == WorkspaceToned(text: "◐ 1 wants out", tone: .wants))
        #expect(header(attention: true).edge == WorkspaceToned(text: "◐ needs a look", tone: .wants))
        #expect(header(phase: "starting", protected: false).edge == WorkspaceToned(text: "· idle", tone: .quiet))
        #expect(header(phase: "starting", protected: false).words == " · starting · 2 panes")
    }

    @Test func everyEdgeHasAWordNotJustAColour() {
        let edges = [
            header(connection: .disconnected), header(pending: 1), header(attention: true),
            header(), header(phase: "idle", protected: false),
        ].map(\.edge)
        #expect(Set(edges.map(\.text)).count == edges.count)
        #expect(edges.allSatisfy { $0.text.count > 2 })
    }

    @Test func projectNameIsStrippedOfEscapes() {
        let evil = WorkspaceHeader.make(project: "/tmp/a\u{1b}[2Jb", connection: .connected,
                                        terminalNeedsAttention: false, phase: "active", protected: true,
                                        panes: 1, agents: 0, pending: 0)
        #expect(evil.name.contains("\u{1b}") == false)
    }

    // MARK: - pane rows

    @Test(arguments: [22, 23, 40, 81, 160])
    func topRowAlwaysFillsThePaneWidth(_ width: Int) {
        for focused in [true, false] {
            for status in ["", "read only", "launch failed", "skipped · recent"] {
                for title in ["zsh", "✳ Claude Code", String(repeating: "t", count: 90), "界面测试"] {
                    let row = WorkspacePaneTopRow.make(width: width, focused: focused, title: title,
                                                       agent: WorkspaceStatusLabel.isAgent(title), status: status)
                    let cells = WorkspacePaneTopRow.leadCells + row.titleCells
                        + WorkspaceCells.width(row.rule) + row.statusCells + 1
                    #expect(cells == width, "\(width) \(focused) \(status) \(title)")
                    #expect(row.titleCells >= 1)
                }
            }
        }
    }

    @Test func focusIsAGlyphAsWellAsAColour() {
        let focused = WorkspacePaneTopRow.make(width: 40, focused: true, title: "zsh", agent: false, status: "")
        let unfocused = WorkspacePaneTopRow.make(width: 40, focused: false, title: "zsh", agent: false, status: "")
        #expect(focused.lead == "╭▸ ")
        #expect(unfocused.lead == "╭─ ")
    }

    @Test func agentPanesAreLabelled() {
        let row = WorkspacePaneTopRow.make(width: 40, focused: true, title: "✳ Claude Code", agent: true, status: "")
        #expect(row.title == "⏺ ✳ Claude Code")
        #expect(WorkspaceStatusLabel.isAgent("codex"))
        #expect(WorkspaceStatusLabel.isAgent("zsh") == false)
    }

    @Test func runningIsSilent() {
        let owned = WorkspaceTerminalState(runtime: UUID(), title: "shell", running: true, lease: .owned)
        let running = WorkspacePane(id: PaneID(), lifecycle: .running)
        #expect(WorkspaceStatusLabel.pane(running, terminal: owned, recentOutputOnly: false)
            == WorkspaceToned(text: "", tone: .quiet))
        let readOnly = WorkspaceTerminalState(runtime: UUID(), title: "shell", running: true, lease: .readOnly)
        #expect(WorkspaceStatusLabel.pane(running, terminal: readOnly, recentOutputOnly: false)
            == WorkspaceToned(text: "read only", tone: .wants))
    }

    @Test func failuresAreStoppedAndCleanExitsQuiet() {
        let id = PaneID()
        #expect(WorkspaceStatusLabel.pane(WorkspacePane(id: id, lifecycle: .launchFailed), terminal: nil,
                                          recentOutputOnly: false).tone == .stopped)
        #expect(WorkspaceStatusLabel.pane(WorkspacePane(id: id, lifecycle: .exited, lastOutcome: .exited(1)),
                                          terminal: nil, recentOutputOnly: false).tone == .stopped)
        #expect(WorkspaceStatusLabel.pane(WorkspacePane(id: id, lifecycle: .exited, lastOutcome: .exited(0)),
                                          terminal: nil, recentOutputOnly: false).tone == .quiet)
        #expect(WorkspaceStatusLabel.pane(WorkspacePane(id: id, lifecycle: .empty), terminal: nil,
                                          recentOutputOnly: false) == WorkspaceToned(text: "new shell", tone: .quiet))
    }

    @Test(arguments: [4, 22, 40, 81])
    func bottomRowFillsThePaneWidthWithOrWithoutAnAsk(_ width: Int) {
        for ask in [nil, "◐ wants out api.stripe.com:443 · ^B R answer"] {
            let row = WorkspacePaneBottomRow.make(width: width, ask: ask)
            let cells = WorkspaceCells.width(row.lead) + row.askCells + WorkspaceCells.width(row.rule) + 1
            #expect(cells == width, "\(width) \(ask ?? "-")")
        }
        let shown = WorkspacePaneBottomRow.make(width: 60, ask: "◐ wants out api.stripe.com:443 · ^B R answer")
        #expect(shown.ask == "◐ wants out api.stripe.com:443 · ^B R answer")
    }

    // MARK: - footer

    @Test func footerTeachesForThreeSessionsThenShrinks() {
        let teach = WorkspaceFooter.text(tabs: 1, panes: 2, teaching: true, connection: .connected, reconnecting: false)
        #expect(teach == "1 tab · 2 panes · ^B ? help · ^B w runtimes · ^B R review")
        #expect(WorkspaceFooter.text(tabs: 1, panes: 2, teaching: false, connection: .connected, reconnecting: false)
            == "^B ?")
        #expect(WorkspaceFooter.teaches(sessionsStarted: nil))
        #expect(WorkspaceFooter.teaches(sessionsStarted: 1))
        #expect(WorkspaceFooter.teaches(sessionsStarted: 3))
        #expect(WorkspaceFooter.teaches(sessionsStarted: 4) == false)
    }

    @Test func aDisconnectedFooterAlwaysSaysSo() {
        #expect(WorkspaceFooter.text(tabs: 1, panes: 1, teaching: false, connection: .disconnected, reconnecting: false)
            == "workspace disconnected · Enter retry · ^B ?")
        #expect(WorkspaceFooter.text(tabs: 2, panes: 1, teaching: true, connection: .disconnected, reconnecting: true)
            == "2 tabs · 1 pane · reconnecting… · ^B ? help · ^B w runtimes · ^B R review")
    }

    // MARK: - cells

    @Test func cellsCountWideCharactersTwice() {
        #expect(WorkspaceCells.width("abc") == 3)
        #expect(WorkspaceCells.width("界面") == 4)
        #expect(WorkspaceCells.clip("界面测试", to: 5) == "界面…")
        #expect(WorkspaceCells.clip("abc", to: 3) == "abc")
        #expect(WorkspaceCells.clip("abcdef", to: 4) == "abc…")
    }
}
