#if os(macOS)
import RVTheme
import SwiftTUICLI

/// The workspace shell's colours: rv's terminal palette (the one `rv term`
/// paints with), one value per meaning. Healthy chrome is neutral; the six
/// colours appear only where they mean something.
///
/// The hex values mirror `TermPaint.Palette.ink` in RVCLI, which this
/// target cannot import; `WorkspaceInkParityTests` in RVCLITests keeps the
/// two tables equal. SwiftTUI maps them down on 256- and 16-colour
/// terminals.
struct WorkspaceInk: Equatable, Sendable {
    enum Token: String, CaseIterable, Sendable {
        /// Body text, the focused pane's border.
        case fg
        /// Secondary text: overlays, the review pane.
        case soft
        /// Quiet chrome: the header's words, tabs, the footer.
        case mute
        /// Unfocused borders and titles.
        case ghost
        /// Hairlines.
        case hair
        /// rv itself: the header's mark.
        case rv
        /// Stopped, failed, disconnected, confirmations that kill.
        case stop
        /// Something wants you: an ask, a pane that needs a look.
        case watch
        /// Fine, done, quiet.
        case ok
        /// Keys to press, commands to type.
        case go
        /// The agent: its name in a pane title.
        case agent
    }

    let background: TerminalBackground

    init(background: TerminalBackground) {
        self.background = background
    }

    func callAsFunction(_ token: Token) -> Color {
        Color(hexRGB: Self.hex(token, background: background))
    }

    var fg: Color { self(.fg) }
    var soft: Color { self(.soft) }
    var mute: Color { self(.mute) }
    var ghost: Color { self(.ghost) }
    var rv: Color { self(.rv) }
    var stop: Color { self(.stop) }
    var watch: Color { self(.watch) }
    var ok: Color { self(.ok) }
    var go: Color { self(.go) }
    var agent: Color { self(.agent) }

    static func hex(_ token: Token, background: TerminalBackground) -> UInt32 {
        let light = background == .light
        switch token {
        case .fg: return light ? 0x1B1B20 : 0xECECF1
        case .soft: return light ? 0x44444E : 0xB9B9C3
        case .mute: return light ? 0x6A6A75 : 0x85858F
        case .ghost: return light ? 0xA2A2AC : 0x50505B
        case .hair: return light ? 0xD9D9E0 : 0x2B2B33
        case .rv: return light ? 0x5A43DC : 0xB8A9FF
        case .stop: return light ? 0xCF222E : 0xFF7A7A
        case .watch: return light ? 0x9A6100 : 0xFFCF6B
        case .ok: return light ? 0x0E7A50 : 0x6EE7B7
        case .go: return light ? 0x0A66C2 : 0x7CC4FF
        case .agent: return light ? 0xA3329C : 0xF0A6FF
        }
    }

    func color(_ tone: WorkspaceTone) -> Color {
        switch tone {
        case .quiet: mute
        case .ok: ok
        case .wants: watch
        case .stopped: stop
        }
    }
}

private struct WorkspaceInkKey: EnvironmentKey {
    static let defaultValue = WorkspaceInk(background: .dark)
}

private struct WorkspaceTeachingKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var workspaceInk: WorkspaceInk {
        get { self[WorkspaceInkKey.self] }
        set { self[WorkspaceInkKey.self] = newValue }
    }

    /// True while the footer still teaches the keys (the first sessions).
    var workspaceTeaching: Bool {
        get { self[WorkspaceTeachingKey.self] }
        set { self[WorkspaceTeachingKey.self] = newValue }
    }
}
#endif
