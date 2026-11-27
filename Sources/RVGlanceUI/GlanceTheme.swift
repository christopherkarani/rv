#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import RVDomain
import SwiftUI

/// Menu bar v5 / v5b colours. Colour carries meaning only: red stopped,
/// amber waiting or watching, green fine, violet rv.
enum GlanceTheme {
    static let stop = adaptive(light: 0xE5484D, dark: 0xFF7A7A)
    static let watch = adaptive(light: 0xD08700, dark: 0xFFCF6B)
    static let ok = adaptive(light: 0x0F9D6B, dark: 0x6EE7B7)
    static let rv = adaptive(light: 0x7C5CFF, dark: 0xB8A9FF)
    static let popoverWidth: CGFloat = 356

    static func avatar(_ host: HookHost) -> Color {
        switch host {
        case .claude: Color(hex: 0xE8A77C)
        case .codex: Color(hex: 0xD9D9E3)
        case .cursor: Color(hex: 0x9FB7FF)
        case .opencode: Color(hex: 0xA7E3C4)
        default: Color(hex: 0xD3C9FF)
        }
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
