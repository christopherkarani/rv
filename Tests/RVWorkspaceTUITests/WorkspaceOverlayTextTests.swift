import Foundation
import Testing
@testable import RVWorkspaceTUI

@Test func resizeHelpIsOneLineWithKeys() {
    let help = WorkspaceOverlayText.resizeHelp()
    #expect(help.contains("h/l"))
    #expect(help.contains("k/j"))
    #expect(help.contains("Enter"))
    #expect(help.contains("Esc"))
    #expect(help.contains("\n") == false)
}

@Test func scrollStatusShowsAnchorAndUnread() {
    #expect(WorkspaceOverlayText.scrollStatus(anchor: 12, unread: false)
        == "SCROLL 12 lines up · q/Esc live")
    #expect(WorkspaceOverlayText.scrollStatus(anchor: 12, unread: true)
        == "SCROLL 12 lines up · q/Esc live · NEW OUTPUT")
    #expect(WorkspaceOverlayText.scrollStatus(anchor: 0, unread: false)
        == "SCROLL 0 lines up · q/Esc live")
}

@Test func navigatorRowsMarkSelected() {
    let tab = TabID()
    let runtime = UUID(uuidString: "12345678-aaaa-bbbb-cccc-dddddddddddd")!
    let items: [NavigatorItem] = [
        .acquireInput,
        .tab(id: tab, title: "editor", index: 0),
        .runtime(id: runtime, label: "shell"),
    ]
    let rows = WorkspaceOverlayText.navigatorRows(
        items: items, selected: 1, tabTitles: [tab: "editor"]
    )
    #expect(rows == [
        "  Acquire input (focused pane)",
        "> Tab 1: editor",
        "  Attach: shell (12345678)",
    ])
}

@Test func navigatorRowsClampSelectedOutOfRange() {
    let items: [NavigatorItem] = [.acquireInput, .releaseInput]
    let high = WorkspaceOverlayText.navigatorRows(items: items, selected: 9, tabTitles: [:])
    #expect(high == [
        "  Acquire input (focused pane)",
        "> Release input (focused pane)",
    ])
    let low = WorkspaceOverlayText.navigatorRows(items: items, selected: -3, tabTitles: [:])
    #expect(low == [
        "> Acquire input (focused pane)",
        "  Release input (focused pane)",
    ])
}

@Test func navigatorRowsEmptyList() {
    #expect(WorkspaceOverlayText.navigatorRows(items: [], selected: 0, tabTitles: [:]) == [])
    #expect(WorkspaceOverlayText.navigatorRows(items: [], selected: 4, tabTitles: [:]) == [])
}

@Test func navigatorRowsSanitizeTitlesAndLabels() {
    let tab = TabID()
    let runtime = UUID()
    let items: [NavigatorItem] = [
        .tab(id: tab, title: "ok", index: 1),
        .runtime(id: runtime, label: "sh\u{1b}[2Jell\u{202E}o"),
        .runtime(id: runtime, label: "\u{07}\u{202B}"),
    ]
    let rows = WorkspaceOverlayText.navigatorRows(
        items: items, selected: 0, tabTitles: [tab: "ed\u{00}itor"]
    )
    #expect(rows[0] == "> Tab 2: editor")
    #expect(rows[1] == "  Attach: sh[2Jello (\(runtime.uuidString.prefix(8)))")
    #expect(rows[2] == "  Attach: runtime (\(runtime.uuidString.prefix(8)))")
}

@Test func navigatorRowsFallBackWhenTitleMissing() {
    let tab = TabID()
    let items: [NavigatorItem] = [.tab(id: tab, title: "\u{07}", index: 2)]
    let rows = WorkspaceOverlayText.navigatorRows(items: items, selected: 0, tabTitles: [:])
    #expect(rows == ["> Tab 3: tab 3"])
}

@Test func confirmTextIsTwoLines() {
    let text = WorkspaceOverlayText.confirmText(paneTitle: "editor")
    #expect(text == "Cancel runtime in editor? y/Enter yes · n/Esc no\n"
        + "The pane keeps its output; the process is killed.")
}

@Test func confirmTextSanitizesAndFallsBack() {
    #expect(WorkspaceOverlayText.confirmText(paneTitle: nil).hasPrefix("Cancel runtime in terminal?"))
    #expect(WorkspaceOverlayText.confirmText(paneTitle: "a\u{1b}b\u{202E}c")
        .hasPrefix("Cancel runtime in abc?"))
}

@Test func modeHintCoversOverlayModesOnly() {
    let pane = PaneID()
    #expect(WorkspaceOverlayText.modeHint(for: .resize) == "RESIZE h/l/k/j · Enter done")
    #expect(WorkspaceOverlayText.modeHint(for: .scroll(pane: pane)) == "SCROLL j/k · q live")
    #expect(WorkspaceOverlayText.modeHint(for: .navigator(index: 0)) == "NAVIGATE j/k · Enter select")
    #expect(WorkspaceOverlayText.modeHint(for: .confirmCancel(pane: pane)) == "CONFIRM y/n")
    #expect(WorkspaceOverlayText.modeHint(for: .terminal) == nil)
    #expect(WorkspaceOverlayText.modeHint(for: .help) == nil)
    #expect(WorkspaceOverlayText.modeHint(for: .launcher) == nil)
}
