#if os(macOS)
import Foundation
import SwiftTUICLI

/// Starts one SwiftTUI application value and owns only local client cleanup.
public enum WorkspaceTUILaunch {
    @MainActor
    public static func run(_ model: WorkspaceTUIModel, pump: TerminalEventPump) async throws {
        pump.start()
        defer {
            pump.stop()
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
        // In terminal mode plain d is consumed by the focused terminal key
        // handler. After Ctrl-G d, the handler deliberately returns ignored so
        // SwiftTUI performs its normal shutdown and restores the user's tty.
        .exitOnKey(.character("d"))
    }
}

struct WorkspaceShellView: View {
    let model: WorkspaceTUIModel
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let snapshot = model.snapshot()
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
            content(snapshot)
            status(snapshot)
        }
        .onKeyPress(.any) { press in
            handle(press)
        }
        .focusable()
        .task {
            while Task.isCancelled == false, model.snapshot().shouldExit == false {
                do {
                    try await Task.sleep(for: .milliseconds(32))
                } catch {
                    return
                }
                model.processPendingWork()
                revision &+= 1
            }
        }
    }

    @ViewBuilder
    private func header(_ snapshot: WorkspaceTUISnapshot) -> some View {
        let name = URL(fileURLWithPath: snapshot.project).lastPathComponent
        let state = snapshot.connection == .connected
            ? (snapshot.protected ? "PROTECTED" : snapshot.phase.uppercased())
            : "DISCONNECTED"
        Text("RV  \(name)  \(state)").bold()
    }

    @ViewBuilder
    private func content(_ snapshot: WorkspaceTUISnapshot) -> some View {
        if snapshot.connection == .disconnected {
            Text("workspace disconnected · ^G d detach")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if snapshot.tree.isEmpty {
            emptyWorkspace(snapshot)
        } else {
            GeometryReader { proxy in
                let _ = model.noteCanvas(width: Int(proxy.size.width), height: Int(proxy.size.height))
                PaneTreeView(shape: snapshot.tree.shape, snapshot: snapshot, model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if snapshot.mode == .help, snapshot.tree.isEmpty == false {
            Text(WorkspaceHelp.text)
        }
        if snapshot.mode == .launcher, snapshot.tree.isEmpty == false {
            Text(launcherText(snapshot.launcher))
        }
    }

    @ViewBuilder
    private func emptyWorkspace(_ snapshot: WorkspaceTUISnapshot) -> some View {
        if snapshot.mode == .launcher {
            VStack(alignment: .center, spacing: 1) {
                Text("New runtime").bold()
                Text("Choose what to launch in this workspace")
                    .foregroundStyle(Color.gray)
                Text(launcherText(snapshot.launcher))
                Text("Esc to cancel").foregroundStyle(Color.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if snapshot.mode == .help {
            Text(WorkspaceHelp.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            VStack(alignment: .center, spacing: 1) {
                Text("No runtimes yet").bold()
                Text("Choose a runtime to begin working here.")
                    .foregroundStyle(Color.gray)
                if snapshot.launcher.isEmpty {
                    Text("No runtime launchers are available.")
                        .foregroundStyle(Color.gray)
                } else {
                    Text(launcherText(snapshot.launcher)).bold()
                        .foregroundStyle(Color.gray)
                    Text("Type its number to launch")
                        .foregroundStyle(Color.gray)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func status(_ snapshot: WorkspaceTUISnapshot) -> some View {
        let state = snapshot.connection == .connected ? "workspace \(snapshot.phase)" : "disconnected"
        let hint: String
        switch snapshot.mode {
        case .terminal:
            hint = snapshot.tree.isEmpty ? "press a number to launch" : "^G n new runtime · ^G ? help"
        case .prefix: hint = "command"
        case .launcher: hint = "1–9 launch · Esc cancel"
        case .help: hint = "Esc close help"
        }
        Text("\(snapshot.runtimeCount) runtimes · \(state) · \(hint)")
            .foregroundStyle(Color.gray)
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
        // The exit binding below is reached only for Ctrl-G d. A plain d in
        // terminal mode is consumed above and sent to the focused runtime.
        return model.snapshot().shouldExit ? .ignored : .handled
    }
}

struct PaneTreeView: View {
    var shape: PaneTree.Shape
    var snapshot: WorkspaceTUISnapshot
    var model: WorkspaceTUIModel

    var body: some View {
        switch shape {
        case .empty:
            Text(" ")
        case .leaf(let id):
            TerminalPaneView(pane: id, snapshot: snapshot, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { proxy in
                let extent = axis == .vertical ? Int(proxy.size.width) : Int(proxy.size.height)
                let firstExtent = splitExtent(extent, ratio: ratio)
                switch axis {
                case .vertical:
                    HStack(spacing: 0) {
                        PaneTreeView(shape: first, snapshot: snapshot, model: model)
                            .frame(width: firstExtent)
                            .frame(maxHeight: .infinity)
                        PaneTreeView(shape: second, snapshot: snapshot, model: model)
                            .frame(width: max(0, extent - firstExtent))
                            .frame(maxHeight: .infinity)
                    }
                case .horizontal:
                    VStack(alignment: .leading, spacing: 0) {
                        PaneTreeView(shape: first, snapshot: snapshot, model: model)
                            .frame(maxWidth: .infinity)
                            .frame(height: firstExtent)
                        PaneTreeView(shape: second, snapshot: snapshot, model: model)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(0, extent - firstExtent))
                    }
                }
            }
        }
    }

    private func splitExtent(_ extent: Int, ratio: SplitRatio) -> Int {
        guard extent > 1 else { return extent }
        return min(extent - 1, max(1, extent * ratio.firstBasisPoints / 10_000))
    }
}

struct TerminalPaneView: View {
    var pane: PaneID
    var snapshot: WorkspaceTUISnapshot
    var model: WorkspaceTUIModel

    var body: some View {
        let state = snapshot.panes[pane]
        let focused = snapshot.focused == pane
        let marker: String
        if snapshot.connection == .disconnected {
            marker = "disconnected"
        } else if state?.running == false {
            marker = "exited\(state?.exitStatus.map { " (\($0))" } ?? "")"
        } else if state?.lease == .readOnly {
            marker = "read-only"
        } else if state?.overflowed == true {
            marker = "● overflow"
        } else {
            marker = "●"
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("\(state?.title ?? "runtime")  \(marker)").bold(focused)
            GeometryReader { proxy in
                let rows = max(1, Int(proxy.size.height))
                let columns = max(1, Int(proxy.size.width))
                let _ = model.noteSize(of: pane, rows: rows, columns: columns, now: Date())
                TerminalCells(frame: model.terminalFrame(for: pane), rows: rows, columns: columns)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .border(focused ? Color.white : Color.gray)
    }
}

struct TerminalCells: View {
    var frame: TerminalFrame?
    var rows: Int
    var columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(rows, 1), id: \.self) { row in
                if let frame, frame.cells.indices.contains(row) {
                    TerminalLine(cells: Array(frame.cells[row].prefix(columns)))
                } else {
                    Text(String(repeating: " ", count: columns))
                }
            }
        }
    }
}

private struct TerminalLine: View {
    var cells: [TerminalCell]

    var body: some View {
        let runs = makeRuns(cells)
        var interpolation = Text.RichContent.StringInterpolation(
            literalCapacity: 0,
            interpolationCount: runs.count
        )
        for run in runs {
            interpolation.appendInterpolation(styledText(run))
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

    private func styledText(_ run: TerminalTextRun) -> Text {
        var text = Text(run.text)
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
    ^G v split vertical    ^G s split horizontal
    ^G h j k l focus       ^G x close pane
    ^G n new runtime       ^G d detach
    ^G ? help
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
