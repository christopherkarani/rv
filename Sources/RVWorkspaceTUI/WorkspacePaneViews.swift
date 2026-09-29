#if os(macOS)
import Foundation
import SwiftTUICLI

struct WorkspacePaneViewport: View {
    let model: WorkspaceTUIModel
    let snapshot: WorkspaceTUISnapshot
    @State private var scrollBaselines: [PaneID: UInt64] = [:]
    @State private var lastScrollPane: PaneID? = nil

    var body: some View {
        GeometryReader { proxy in
            let rows = max(0, Int(proxy.size.height))
            let columns = max(0, Int(proxy.size.width))
            let plan = WorkspacePaneRenderPlan.make(view: snapshot.view, columns: columns, rows: rows)
            let scrollPane = Self.scrollPaneID(snapshot.mode)
            let _ = syncScrollBaseline(scrollPane: scrollPane)
            let _ = model.noteViewport(rows: rows, columns: columns)
            if plan.state == .ready {
                let _ = noteVisibleSizes(plan)
                VStack(alignment: .leading, spacing: 0) {
                    if plan.focusedFallback {
                        Text("Terminal too small — showing focused pane")
                            .foregroundStyle(.yellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    PaneCanvasLayout(viewport: plan.viewport, placements: plan.placements) {
                        ForEach(plan.placements, id: \.id) { placement in
                            if let pane = snapshot.view.panes[placement.id] {
                                WorkspacePanePanel(
                                    pane: pane,
                                    terminal: snapshot.terminals[placement.id],
                                    frame: frame(
                                        for: placement.id, placement: placement,
                                        scrollPane: scrollPane
                                    ),
                                    placement: placement,
                                    focused: placement.id == plan.focusedPaneID,
                                    recentOutputOnly: snapshot.recentOutputOnly.contains(placement.id),
                                    scrolling: scrollPane == placement.id,
                                    hasNewOutput: hasNewOutput(
                                        paneID: placement.id, scrollPane: scrollPane
                                    )
                                )
                                .id(placement.id)
                                .layoutValue(key: PaneLayoutID.self, value: placement.id)
                            }
                        }
                    }
                }
            } else if plan.state == .tooSmall {
                Text("terminal too small for this layout")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Text("New shell · Ctrl-B a launcher · Ctrl-B w runtimes")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private static func scrollPaneID(_ mode: CommandMode) -> PaneID? {
        if case .scroll(let pane) = mode { return pane }
        return nil
    }

    /// Captures the scrolled pane's frame revision when scroll mode opens so
    /// later output can raise the unread marker. Converges: after the
    /// transition pass the stored values already match and nothing is set.
    @MainActor private func syncScrollBaseline(scrollPane: PaneID?) {
        if scrollPane != lastScrollPane {
            lastScrollPane = scrollPane
            if let scrollPane {
                scrollBaselines[scrollPane] = snapshot.frameRevisions[scrollPane] ?? 0
            }
        } else if let scrollPane, scrollBaselines[scrollPane] == nil {
            scrollBaselines[scrollPane] = snapshot.frameRevisions[scrollPane] ?? 0
        }
    }

    @MainActor private func frame(for paneID: PaneID, placement: PanePlacement, scrollPane: PaneID?) -> TerminalFrame? {
        if scrollPane == paneID,
           let scrolled = model.scrollFrame(for: paneID, rows: placement.content.height) {
            return scrolled
        }
        return model.terminalFrame(for: paneID)
    }

    @MainActor private func hasNewOutput(paneID: PaneID, scrollPane: PaneID?) -> Bool {
        guard scrollPane == paneID,
              let baseline = scrollBaselines[paneID],
              let current = snapshot.frameRevisions[paneID] else { return false }
        return current > baseline
    }

    private func noteVisibleSizes(_ plan: WorkspacePaneRenderPlan) {
        for placement in plan.placements {
            model.noteSize(for: placement.id, rows: placement.content.height,
                           columns: placement.content.width, now: Date())
        }
    }
}

struct WorkspacePanePanel: View {
    let pane: WorkspacePane
    let terminal: WorkspaceTerminalState?
    let frame: TerminalFrame?
    let placement: PanePlacement
    let focused: Bool
    let recentOutputOnly: Bool
    let scrolling: Bool
    let hasNewOutput: Bool

    private func borderColumn(rows: Int) -> String {
        Array(repeating: "│", count: rows).joined(separator: "\n")
    }

    var body: some View {
        let width = placement.outer.width
        let contentWidth = placement.content.width
        let contentHeight = placement.content.height
        let border: Color = focused ? .green : .gray
        let status = scrolling
            ? (hasNewOutput ? "SCROLL • new" : "SCROLL")
            : WorkspacePaneChrome.status(pane, terminal: terminal,
                                         recentOutputOnly: recentOutputOnly)
        let statusWidth = min(20, max(10, width / 3))
        let titleWidth = max(0, width - 2 - statusWidth)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(focused ? "●" : "╭").foregroundStyle(border)
                Text(" \(WorkspacePaneChrome.title(pane, terminal: terminal))")
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: titleWidth, height: 1, alignment: .leading)
                Text(status).foregroundStyle(status == "running" ? Color.green : Color.yellow)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: statusWidth, height: 1, alignment: .trailing)
                Text("╮").foregroundStyle(border)
            }
            .frame(width: width, height: 1, alignment: .leading)
            if contentHeight > 0 {
                HStack(spacing: 0) {
                    Text(borderColumn(rows: contentHeight)).foregroundStyle(border)
                    TerminalBlock(rows: (0..<contentHeight).map { row in
                        TerminalCellClipper.clipped(
                            frame.flatMap { $0.cells.indices.contains(row) ? $0.cells[row] : nil } ?? [],
                            columns: contentWidth
                        )
                    })
                    .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                    Text(borderColumn(rows: contentHeight)).foregroundStyle(border)
                }
                .frame(width: width, height: contentHeight, alignment: .leading)
            }
            Text("╰" + String(repeating: "─", count: max(0, width - 2)) + "╯")
                .foregroundStyle(border)
                .frame(width: width, height: 1, alignment: .leading)
        }
        .frame(width: width, height: placement.outer.height, alignment: .topLeading)
    }
}
#endif
