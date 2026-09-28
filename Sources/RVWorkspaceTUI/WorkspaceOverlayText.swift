import Foundation

/// Pure overlay strings for workspace TUI overlay modes. No rendering, no I/O.
enum WorkspaceOverlayText {
    static func resizeHelp() -> String {
        "RESIZE h/l vertical · k/j horizontal · Enter/Esc done"
    }

    static func scrollStatus(anchor: Int, unread: Bool) -> String {
        let base = "SCROLL \(max(0, anchor)) lines up · q/Esc live"
        return unread ? base + " · NEW OUTPUT" : base
    }

    static func navigatorRows(
        items: [NavigatorItem],
        selected: Int,
        tabTitles: [TabID: String]
    ) -> [String] {
        guard items.isEmpty == false else { return [] }
        let clamped = min(max(0, selected), items.count - 1)
        return items.enumerated().map { offset, item in
            let marker = offset == clamped ? "> " : "  "
            return marker + navigatorLabel(for: item, tabTitles: tabTitles)
        }
    }

    static func confirmText(paneTitle: String?) -> String {
        let title = WorkspacePaneChrome.safe(paneTitle) ?? "terminal"
        return "Cancel runtime in \(title)? y/Enter yes · n/Esc no\n"
            + "The pane keeps its output; the process is killed."
    }

    /// One-line footer hint while an overlay mode is active; nil otherwise.
    static func modeHint(for mode: CommandMode) -> String? {
        switch mode {
        case .resize: "RESIZE h/l/k/j · Enter done"
        case .scroll: "SCROLL j/k · q live"
        case .navigator: "NAVIGATE j/k · Enter select"
        case .confirmCancel: "CONFIRM y/n"
        case .terminal, .prefix, .help, .launcher, .runCommand: nil
        }
    }

    private static func navigatorLabel(for item: NavigatorItem, tabTitles: [TabID: String]) -> String {
        switch item {
        case .acquireInput:
            return "Acquire input (focused pane)"
        case .releaseInput:
            return "Release input (focused pane)"
        case .tab(let id, let title, let index):
            let number = index + 1
            let safe = WorkspacePaneChrome.safe(tabTitles[id])
                ?? WorkspacePaneChrome.safe(title)
                ?? "tab \(number)"
            return "Tab \(number): \(safe)"
        case .runtime(let id, let label):
            let safe = WorkspacePaneChrome.safe(label) ?? "runtime"
            return "Attach: \(safe) (\(id.uuidString.prefix(8)))"
        }
    }
}
