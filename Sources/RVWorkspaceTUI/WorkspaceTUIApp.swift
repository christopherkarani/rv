#if os(macOS)
import Foundation
import SwiftTUICLI

/// Starts one SwiftTUI application value and owns only local session cleanup.
/// Event delivery starts here and stops inside `detachSession`.
public enum WorkspaceTUILaunch {
    @MainActor
    public static func run(_ model: WorkspaceTUIModel) async throws {
        model.startEventDelivery()
        defer {
            model.detachSession()
        }
        try await TerminalRunner.run(WorkspaceShellApp(model: model))
    }
}

struct WorkspaceShellApp: App {
    private let model: WorkspaceTUIModel?

    nonisolated init() {
        model = nil
    }

    init(model: WorkspaceTUIModel) {
        self.model = model
    }

    var body: some Scene {
        WindowGroup("RV") {
            if let model {
                WorkspaceShellView(model: model)
            } else {
                Text("RV workspace is not connected")
            }
        }
        // In terminal mode plain d is consumed by the terminal key handler.
        // After Ctrl-B q, the handler deliberately returns ignored so
        // SwiftTUI performs its normal shutdown and restores the user's tty.
        .exitOnKey(.character("q"))
    }
}

struct WorkspaceShellView: View {
    let model: WorkspaceTUIModel
    @State private var revision = 0
    @Environment(\.requestTermination) private var requestTermination

    var body: some View {
        let _ = revision
        let snapshot = model.snapshot()
        let terminate = requestTermination
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
            tabStrip(snapshot)
            content(snapshot)
            footer(snapshot)
        }
        .onKeyPress(.any) { press in
            handle(press)
        }
        .onPaste { content in
            model.handlePaste(content)
            revision &+= 1
            return .handled
        }
        .focusable()
        .task {
            var refreshGate = WorkspaceTUIRefreshGate(revision: snapshot.presentationRevision)
            while Task.isCancelled == false, model.snapshot().shouldExit == false {
                do {
                    try await Task.sleep(for: .milliseconds(32))
                } catch {
                    return
                }
                model.processPendingWork()
                if refreshGate.consume(model.snapshot().presentationRevision) {
                    revision &+= 1
                }
            }
            // shouldExit can also come from closing the final pane, where no
            // exit key was pressed. Terminate programmatically so every
            // detach path shuts the scene down; the Ctrl-B q binding may have
            // already done so, which is idempotent.
            if Task.isCancelled == false, model.snapshot().shouldExit {
                terminate()
            }
        }
    }

    @ViewBuilder
    private func header(_ snapshot: WorkspaceTUISnapshot) -> some View {
        let name = URL(fileURLWithPath: snapshot.project).lastPathComponent
        let terminalNeedsAttention = snapshot.terminal?.running == false
            || snapshot.terminal?.lease == .readOnly
            || snapshot.terminal?.overflowed == true
        let indicatorColor: Color
        if snapshot.connection == .disconnected {
            indicatorColor = .red
        } else if terminalNeedsAttention {
            indicatorColor = .yellow
        } else if snapshot.phase == "active", snapshot.protected {
            indicatorColor = .green
        } else {
            indicatorColor = .yellow
        }
        HStack(spacing: 1) {
            Text("RV  \(name)").bold()
            Spacer(minLength: 0)
            Text("●").foregroundStyle(indicatorColor)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func content(_ snapshot: WorkspaceTUISnapshot) -> some View {
        ZStack(alignment: .bottomLeading) {
            WorkspacePaneViewport(model: model, snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if snapshot.mode == .help {
                Text(WorkspaceHelp.text)
                    .foregroundStyle(Color.yellow)
            }
            if snapshot.mode == .launcher {
                Text(launcherText(snapshot.launcher) + "    Esc close")
                    .foregroundStyle(Color.yellow)
            }
            if case .runCommand(let input, let error) = snapshot.mode {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Run command: " + input).foregroundStyle(Color.yellow).lineLimit(1)
                    if let error {
                        Text(error).foregroundStyle(Color.red).lineLimit(1)
                    }
                    Text("Enter run · Esc launcher").foregroundStyle(Color.gray)
                }
            }
            if snapshot.mode == .resize {
                Text(WorkspaceOverlayText.resizeHelp())
                    .foregroundStyle(Color.yellow)
            }
            if case .scroll(let pane) = snapshot.mode {
                Text(WorkspaceOverlayText.scrollStatus(
                    anchor: snapshot.scrollAnchors[pane] ?? 0, unread: false
                ))
                .foregroundStyle(Color.yellow)
            }
            if case .navigator(let index) = snapshot.mode {
                Text(WorkspaceOverlayText.navigatorRows(
                    items: snapshot.navigatorItems,
                    selected: index,
                    tabTitles: navigatorTabTitles(snapshot.view)
                ).joined(separator: "\n"))
                .foregroundStyle(Color.yellow)
            }
            if case .confirmCancel(let pane) = snapshot.mode {
                let title = snapshot.view.panes[pane].map {
                    WorkspacePaneChrome.title($0, terminal: snapshot.terminals[pane])
                }
                Text(WorkspaceOverlayText.confirmText(paneTitle: title))
                    .foregroundStyle(Color.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func tabStrip(_ snapshot: WorkspaceTUISnapshot) -> some View {
        let tabs = snapshot.view.tabs.enumerated().map { index, tab in
            let title = WorkspacePaneChrome.safe(tab.userTitle) ?? "tab \(index + 1)"
            return "\(tab.id == snapshot.view.activeTabID ? "●" : "○") \(index + 1):\(String(title.prefix(12)))"
        }
        Text(tabs.isEmpty ? "No tabs" : tabs.joined(separator: "   "))
            .foregroundStyle(Color.gray)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func footer(_ snapshot: WorkspaceTUISnapshot) -> some View {
        let count = snapshot.view.activeTab?.tree.leafCount ?? 0
        let connection: String
        if snapshot.connection == .disconnected {
            connection = snapshot.reconnecting ? " · reconnecting…" : " · workspace disconnected · Enter retry"
        } else {
            connection = ""
        }
        let hint = snapshot.feedback
            ?? WorkspaceOverlayText.modeHint(for: snapshot.mode)
            ?? "\(snapshot.view.tabs.count) tabs · \(count) panes\(connection) · Ctrl-B ? help · Ctrl-B w runtimes"
        Text(hint)
            .foregroundStyle(snapshot.feedback == nil ? Color.gray : Color.yellow)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func navigatorTabTitles(_ view: WorkspaceView) -> [TabID: String] {
        var titles: [TabID: String] = [:]
        for (index, tab) in view.tabs.enumerated() {
            titles[tab.id] = tab.userTitle ?? "tab \(index + 1)"
        }
        return titles
    }

    private func launcherText(_ choices: [RuntimeLaunchChoice]) -> String {
        guard choices.isEmpty == false else { return "no launchers available · Esc close" }
        return choices.enumerated()
            .map { "\($0.offset + 1) \($0.element.title)" }
            .joined(separator: "    ")
    }

    private func handle(_ press: KeyPress) -> KeyPressResult {
        guard let key = TUIKeyDecoder.decode(press) else { return .ignored }
        model.handle(key)
        revision &+= 1
        // The exit binding below is reached only for Ctrl-B q. A plain q in
        // terminal mode is consumed above and sent to the runtime.
        return model.snapshot().shouldExit ? .ignored : .handled
    }
}

/// One pane's content as a single multiline Text. A per-row ForEach costs
/// one subtree per row in every frame's resolve/measure/place/commit pass;
/// at 8 panes that is thousands of nodes and seconds per frame. Rows are
/// pre-clipped to the content width so no wrapping can reflow the block.
struct TerminalBlock: View {
    var rows: [[TerminalCell]]

    var body: some View {
        let rowRuns = rows.map(makeRuns)
        var interpolation = Text.RichContent.StringInterpolation(
            literalCapacity: 0,
            interpolationCount: rowRuns.reduce(0) { $0 + $1.count }
        )
        for (index, runs) in rowRuns.enumerated() {
            // A lone "\n" segment renders as U+FFFD, so the break rides
            // inside the row's final run instead.
            let suffixed = index + 1 < rowRuns.count
            // Rows arrive pre-padded to the content width, so runs is only
            // empty for a zero-width pane, where nothing can show anyway.
            for (runIndex, run) in runs.enumerated() {
                let text = runIndex + 1 == runs.count && suffixed ? run.text + "\n" : run.text
                interpolation.appendInterpolation(styledText(run, text: text))
            }
        }
        return Text(Text.RichContent(stringInterpolation: interpolation))
    }

    private func makeRuns(_ cells: [TerminalCell]) -> [TerminalTextRun] {
        var runs: [TerminalTextRun] = []
        for cell in cells {
            let style = TerminalTextStyle(
                bold: cell.bold,
                underline: cell.underline,
                inverse: cell.inverse != cell.cursor,
                foreground: cell.foreground,
                background: cell.background,
                italic: cell.italic,
                dim: cell.dim,
                strikethrough: cell.strikethrough
            )
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += cell.text
            } else {
                runs.append(TerminalTextRun(text: cell.text, style: style))
            }
        }
        return runs
    }

    private func styledText(_ run: TerminalTextRun, text content: String? = nil) -> Text {
        var text = Text(content ?? run.text)
        if let foreground = run.style.foreground {
            text = text.foregroundStyle(color(foreground))
        }
        if let background = run.style.background {
            text = text.cellBackground(color(background))
        }
        return text
            .bold(run.style.bold)
            .underline(run.style.underline)
            .reverse(run.style.inverse)
            .italic(run.style.italic)
            .faint(run.style.dim)
            .strikethrough(run.style.strikethrough)
    }

    private func color(_ value: TerminalColor) -> Color {
        Color(
            red: Double(value.red) / 255,
            green: Double(value.green) / 255,
            blue: Double(value.blue) / 255
        )
    }
}

private struct TerminalTextStyle: Equatable {
    var bold: Bool
    var underline: Bool
    var inverse: Bool
    var foreground: TerminalColor?
    var background: TerminalColor?
    var italic: Bool
    var dim: Bool
    var strikethrough: Bool
}

private struct TerminalTextRun {
    var text: String
    var style: TerminalTextStyle
}

enum WorkspaceHelp {
    static let text = """
    ^B v split right   ^B - split below   ^B h/j/k/l focus   ^B z zoom
    ^B c new tab       ^B n/p next/previous tab       ^B x close pane
    ^B r resize        ^B [ scroll        ^B w runtimes      ^B a launcher
    ^B ! cancel runtime (confirm)         ^B q detach       ^B ^B literal Ctrl-B
    Esc closes help and menus
    """
}

enum TUIKeyDecoder {
    struct PrintableModifiers: OptionSet {
        let rawValue: UInt8
        static let shift = Self(rawValue: 1 << 0)
    }

    static func decode(_ press: KeyPress) -> TUIKey? {
        if press.modifiers.contains(.alt) {
            let unmodified = KeyPress(press.key, modifiers: press.modifiers.subtracting(.alt))
            guard let key = decode(unmodified) else { return nil }
            return .alt(key)
        }
        let nonShiftModifiers = press.modifiers.subtracting(.shift)
        if press.modifiers.contains(.ctrl), nonShiftModifiers.subtracting(.ctrl).isEmpty {
            if case .character(let character) = press.key {
                return .control(character)
            }
            if case .space = press.key { return .control("@") }
        }
        switch press.key {
        case .character(let character) where nonShiftModifiers.isEmpty:
            return decodePrintable(character, modifiers: printableModifiers(press))
        case .space where nonShiftModifiers.isEmpty:
            return decodePrintable(" ", modifiers: printableModifiers(press))
        case .escape: return .escape
        case .return: return .enter
        case .tab: return .tab
        case .backspace: return .backspace
        case .delete: return .delete
        case .arrowUp: return .arrow(.up)
        case .arrowDown: return .arrow(.down)
        case .arrowLeft: return .arrow(.left)
        case .arrowRight: return .arrow(.right)
        case .home: return .home
        case .end: return .end
        case .insert: return .insert
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .functionKey(let number): return .functionKey(number)
        default: return nil
        }
    }

    static func decodePrintable(_ character: Character, modifiers: PrintableModifiers) -> TUIKey? {
        guard modifiers.subtracting(.shift).isEmpty else { return nil }
        // SwiftTUI's key identity already contains the printable shifted
        // character (for example "A" or "?"); Shift is not a reason to drop it.
        return .character(character)
    }

    private static func printableModifiers(_ press: KeyPress) -> PrintableModifiers {
        var modifiers: PrintableModifiers = []
        if press.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
#endif
