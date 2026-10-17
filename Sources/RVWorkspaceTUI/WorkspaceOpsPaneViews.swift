import Foundation

/// Pure render text for ops panes: panel chrome, list window, and the detail
/// overlay. No rendering, no I/O — like `WorkspaceOverlayText` — so the whole
/// contract is unit-testable without SwiftTUI.
enum WorkspaceOpsPaneText {
    /// One rendered list line plus the style flags the view maps to color and
    /// emphasis. `text` is already sanitized and single-line.
    struct Row: Equatable, Sendable {
        var text: String
        var cursor: Bool
        var inRange: Bool
        var denied: Bool
    }

    /// The panel's content lines for one frame. Either bar is nil when the
    /// content area is too short to show it; rows fill whatever is left.
    struct Content: Equatable, Sendable {
        var filterBar: String?
        var rows: [Row]
        var statusRow: String?
    }

    static func title(_ pane: WorkspacePane) -> String {
        WorkspacePaneChrome.safe(pane.userTitle) ?? "ops"
    }

    /// Title-row status word. The view colors `follow` green and everything
    /// else yellow, mirroring the terminal panel's running/other split.
    static func titleStatus(_ ops: OpsPaneState?) -> String {
        guard let ops, ops.loaded else { return "loading" }
        return ops.follow ? "follow" : "paused"
    }

    /// Lays out one frame: filter bar on top (height >= 2), status row at the
    /// bottom (height >= 3), event rows between. A nil state renders as an
    /// unloaded pane, covering the tick before history lands.
    static func content(ops: OpsPaneState?, height: Int) -> Content {
        guard height > 0 else { return Content(filterBar: nil, rows: [], statusRow: nil) }
        let state = ops ?? .initial()
        let filterBar = height >= 2 ? filterBarText(state) : nil
        let statusRow = height >= 3 ? statusRowText(state) : nil
        let rowsHeight = height - (filterBar == nil ? 0 : 1) - (statusRow == nil ? 0 : 1)
        return Content(
            filterBar: filterBar,
            rows: eventRows(state, height: max(0, rowsHeight)),
            statusRow: statusRow
        )
    }

    /// The detail overlay for the focused pane, or nil when no detail is open.
    /// The shell renders it like the other overlays: yellow text over the tab.
    static func detailOverlay(pane: WorkspacePane, ops: OpsPaneState?) -> String? {
        guard pane.content == .ops, let ops,
              let index = ops.detailIndex,
              ops.filtered.indices.contains(index) else { return nil }
        return "DETAIL · Enter/Esc close\n"
            + sanitize(OpsPaneFormat.detail(ops.filtered[index]), preserveNewlines: true)
    }

    /// Drops the same bytes `WorkspacePaneChrome.safe` drops (control
    /// characters and bidi overrides) without truncating or trimming, so
    /// audit subjects cannot inject layout or escape sequences. Single-line
    /// callers get newlines, carriage returns, and tabs as spaces; block
    /// callers keep newlines and drop carriage returns.
    static func sanitize(_ raw: String, preserveNewlines: Bool = false) -> String {
        let space = UnicodeScalar(" ")
        let scalars = raw.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            if scalar == UnicodeScalar("\n") { return preserveNewlines ? scalar : space }
            if scalar == UnicodeScalar("\r") { return nil }
            if scalar == UnicodeScalar("\t") { return space }
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) { return nil }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: - Private

    private static func filterBarText(_ state: OpsPaneState) -> String {
        let count = state.loaded ? "\(state.filtered.count) events" : "loading…"
        return "filter: \(state.filter.label) · \(count)"
    }

    private static func statusRowText(_ state: OpsPaneState) -> String {
        if state.detailIndex != nil { return "Detail · Enter/Esc close" }
        let count = state.filtered.count
        let position = count == 0 ? 0 : min(max(0, state.cursorIndex), count - 1) + 1
        if state.selectionAnchor != nil {
            return "\(position)/\(count) · VISUAL · y yank · v clear"
        }
        return "\(position)/\(count) · j/k move · f follow · / filter · Enter detail · y yank"
    }

    private static func eventRows(_ state: OpsPaneState, height: Int) -> [Row] {
        guard height > 0 else { return [] }
        guard state.loaded else {
            return [Row(text: "loading audit history…", cursor: false, inRange: false, denied: false)]
        }
        let filtered = state.filtered
        guard filtered.isEmpty == false else {
            let text = state.filter == .all
                ? "no audit events"
                : "no events match filter \(state.filter.label)"
            return [Row(text: text, cursor: false, inRange: false, denied: false)]
        }
        // The state's viewport is the full content height including both bars,
        // so the window re-derives its start here; the cursor stays visible
        // even when the stored offset belongs to a taller area.
        let span = max(1, height)
        let cursor = min(max(0, state.cursorIndex), filtered.count - 1)
        var start = min(max(0, state.scrollOffset), max(0, filtered.count - span))
        if cursor < start {
            start = cursor
        } else if cursor >= start + span {
            start = cursor - span + 1
        }
        let end = min(filtered.count, start + span)
        var range: ClosedRange<Int>?
        if let anchor = state.selectionAnchor {
            let clamped = min(max(0, anchor), filtered.count - 1)
            range = min(clamped, cursor)...max(clamped, cursor)
        }
        return (start..<end).map { index in
            Row(
                text: sanitize(OpsPaneFormat.row(filtered[index])),
                cursor: index == cursor,
                inRange: range?.contains(index) ?? false,
                denied: filtered[index].decision == .denied
            )
        }
    }
}

#if os(macOS)
import SwiftTUICLI

/// One ops pane framed exactly like `WorkspacePanePanel`: indicator, title,
/// and status on top, bordered content, closing rule. The content swaps the
/// terminal emulator for the audit list: filter bar, compact event rows with
/// cursor highlight, and a status row with key hints.
struct WorkspaceOpsPanePanel: View {
    let pane: WorkspacePane
    let ops: OpsPaneState?
    let placement: PanePlacement
    let focused: Bool

    private func borderColumn(rows: Int) -> String {
        Array(repeating: "│", count: rows).joined(separator: "\n")
    }

    var body: some View {
        let width = placement.outer.width
        let contentWidth = placement.content.width
        let contentHeight = placement.content.height
        let border: Color = focused ? .green : .gray
        let status = WorkspaceOpsPaneText.titleStatus(ops)
        let indicator = WorkspaceStatusLabel.paneIndicator(focused: focused)
        let statusWidth = WorkspaceStatusLabel.paneStatusWidth(outerWidth: width)
        let titleWidth = WorkspaceStatusLabel.paneTitleWidth(outerWidth: width, focused: focused)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(indicator).foregroundStyle(border)
                Text(" \(WorkspaceOpsPaneText.title(pane))")
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: titleWidth, height: 1, alignment: .leading)
                Text(status).foregroundStyle(status == "follow" ? Color.green : Color.yellow)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: statusWidth, height: 1, alignment: .trailing)
                Text("╮").foregroundStyle(border)
            }
            .frame(width: width, height: 1, alignment: .leading)
            if contentHeight > 0 {
                HStack(spacing: 0) {
                    Text(borderColumn(rows: contentHeight)).foregroundStyle(border)
                    OpsBlock(
                        content: WorkspaceOpsPaneText.content(ops: ops, height: contentHeight),
                        width: contentWidth,
                        height: contentHeight
                    )
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

/// One pane's ops content as a single multiline Text, following `TerminalBlock`:
/// one subtree per pane instead of one per row, rows pre-clipped to the content
/// width so no wrapping can reflow the block, and the line break riding inside
/// each run because a lone "\n" segment renders as U+FFFD.
struct OpsBlock: View {
    var content: WorkspaceOpsPaneText.Content
    var width: Int
    var height: Int

    private struct Run {
        var text: String
        var foreground: Color?
        var reverse: Bool
        var underline: Bool
    }

    var body: some View {
        var runs: [Run] = []
        if let filterBar = content.filterBar {
            runs.append(Run(text: clipped(filterBar), foreground: .gray, reverse: false, underline: false))
        }
        for row in content.rows {
            runs.append(Run(
                text: clipped(row.text),
                foreground: row.denied ? .red : nil,
                reverse: row.cursor,
                underline: row.inRange && row.cursor == false
            ))
        }
        // Blank lines sit above the status row so the filter bar stays pinned
        // to the top and the status row to the bottom at any event count.
        let blanks = max(0, height - runs.count - (content.statusRow == nil ? 0 : 1))
        runs += Array(repeating: Run(text: clipped(""), foreground: nil, reverse: false, underline: false), count: blanks)
        if let statusRow = content.statusRow {
            runs.append(Run(text: clipped(statusRow), foreground: .gray, reverse: false, underline: false))
        }
        var interpolation = Text.RichContent.StringInterpolation(
            literalCapacity: 0,
            interpolationCount: runs.count
        )
        for (index, run) in runs.enumerated() {
            let suffixed = index + 1 < runs.count
            var styled = Text(suffixed ? run.text + "\n" : run.text)
            if let foreground = run.foreground {
                styled = styled.foregroundStyle(foreground)
            }
            styled = styled.reverse(run.reverse).underline(run.underline)
            interpolation.appendInterpolation(styled)
        }
        return Text(Text.RichContent(stringInterpolation: interpolation))
    }

    private func clipped(_ line: String) -> String {
        let count = max(0, width)
        let prefix = String(line.prefix(count))
        return prefix + String(repeating: " ", count: max(0, count - prefix.count))
    }
}
#endif
