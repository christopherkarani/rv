#if os(macOS)
import RVTheme
import SwiftTUICLI

/// The workspace shell's chrome colors for the terminal background. Dark
/// keeps SwiftTUI's named colors; light swaps them for darker ones that
/// stay readable on white.
struct WorkspaceInk: Equatable, Sendable {
    /// Overlays, notices, and states that need a look.
    var attention: Color
    /// Focused, running, protected.
    var ok: Color
    /// Hints, tabs, unfocused borders.
    var muted: Color
    /// Disconnected, errors, confirmations.
    var danger: Color

    init(background: TerminalBackground) {
        switch background {
        case .dark:
            attention = .yellow
            ok = .green
            muted = .gray
            danger = .red
        case .light:
            attention = Color(hexRGB: 0x8A5A00)
            ok = Color(hexRGB: 0x1E7B34)
            muted = Color(hexRGB: 0x5C6370)
            danger = Color(hexRGB: 0xB42318)
        }
    }
}

private struct WorkspaceInkKey: EnvironmentKey {
    static let defaultValue = WorkspaceInk(background: .dark)
}

extension EnvironmentValues {
    var workspaceInk: WorkspaceInk {
        get { self[WorkspaceInkKey.self] }
        set { self[WorkspaceInkKey.self] = newValue }
    }
}
#endif
