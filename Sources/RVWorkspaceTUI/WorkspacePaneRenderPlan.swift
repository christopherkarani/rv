import Foundation

/// Immutable geometry for one visible tab. Hidden tabs never enter this plan.
struct WorkspacePaneRenderPlan: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case empty
        case ready
        case tooSmall
    }

    let state: State
    let viewport: CellRect
    let placements: [PanePlacement]
    let dividers: [DividerPlacement]
    let focusedPaneID: PaneID?
    /// True when the full layout could not fit and the plan shows only the
    /// focused pane in the whole viewport.
    let focusedFallback: Bool

    var visiblePaneIDs: [PaneID] { placements.map(\.id) }

    static func make(view: WorkspaceView, columns: Int, rows: Int) -> Self {
        let viewport = CellRect(x: 0, y: 0, width: max(0, columns), height: max(0, rows))
        guard let tab = view.activeTab else {
            return Self(state: .empty, viewport: viewport, placements: [], dividers: [],
                        focusedPaneID: nil, focusedFallback: false)
        }
        let tree: PaneTree
        if let zoom = tab.zoomedPaneID, tab.tree.leafIDs.contains(zoom) {
            tree = .leaf(zoom)
        } else {
            tree = tab.tree
        }
        guard let geometry = PaneGeometry.solve(tree, in: viewport) else {
            if tab.tree.leafIDs.contains(tab.focusedPaneID),
               let fallback = PaneGeometry.solve(.leaf(tab.focusedPaneID), in: viewport) {
                return Self(state: .ready, viewport: viewport, placements: fallback.placements,
                            dividers: fallback.dividers, focusedPaneID: tab.focusedPaneID,
                            focusedFallback: true)
            }
            return Self(state: .tooSmall, viewport: viewport, placements: [], dividers: [],
                        focusedPaneID: tab.focusedPaneID, focusedFallback: false)
        }
        return Self(state: .ready, viewport: viewport, placements: geometry.placements,
                    dividers: geometry.dividers, focusedPaneID: tab.focusedPaneID,
                    focusedFallback: false)
    }
}

enum WorkspacePaneChrome {
    static func title(_ pane: WorkspacePane, terminal: WorkspaceTerminalState?) -> String {
        safe(pane.userTitle) ?? safe(terminal?.title) ?? "terminal"
    }

    static func status(_ pane: WorkspacePane, terminal: WorkspaceTerminalState?,
                       recentOutputOnly: Bool = false) -> String {
        if terminal?.overflowed == true {
            return recentOutputOnly ? "skipped · recent" : "output skipped"
        }
        if recentOutputOnly { return "recent output only" }
        // The lifecycle tells the truth; a stale read-only lease must never
        // mask it (after a crash, missing runtimes would read as merely
        // unowned). The lease refines the running state only.
        switch pane.lifecycle {
        case .empty: return "new shell"
        case .launching: return "launching"
        case .attaching: return "attaching"
        case .running:
            if terminal?.lease == .readOnly { return "read only" }
            return terminal?.lease == .owned ? "running" : "running · no input"
        case .exited:
            if case .exited(let code)? = pane.lastOutcome { return "exited \(code)" }
            return "exited"
        case .launchFailed: return "launch failed"
        case .disconnected: return "disconnected"
        case .missing: return "runtime missing"
        }
    }

    /// Control bytes and bidi overrides must not turn pane labels into terminal control or misleading chrome.
    static func safe(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let filtered = String(String.UnicodeScalarView(raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
                !((0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value))
        }))
        let compact = String(filtered.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? nil : compact
    }
}

enum TerminalCellClipper {
    /// A wide glyph whose continuation lies outside the viewport cannot be painted in one cell.
    static func clipped(_ cells: [TerminalCell], columns: Int) -> [TerminalCell] {
        let count = max(0, columns)
        guard count > 0 else { return [] }
        var visible = Array(cells.prefix(count))
        if visible.count == count, cells.count > count,
           cells[count].text.isEmpty, !visible[count - 1].text.isEmpty {
            visible[count - 1] = TerminalCell(text: " ")
        }
        if visible.count < count {
            visible += Array(repeating: TerminalCell(text: " "), count: count - visible.count)
        }
        return visible
    }
}
