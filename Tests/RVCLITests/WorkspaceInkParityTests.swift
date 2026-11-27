#if os(macOS)
import RVTerm
import RVTheme
import Testing
@testable import RVCLI
@testable import RVWorkspaceTUI

/// The workspace shell paints with `rv term`'s palette. RVWorkspaceTUI
/// cannot import RVCLI, so it keeps a copy of the table; this keeps the
/// two equal, token by token, on both backgrounds.
@Test func workspaceInkMatchesTheTermPalette() {
    let pairs: [(WorkspaceInk.Token, TermInk)] = [
        (.fg, .fg), (.soft, .soft), (.mute, .mute), (.ghost, .ghost), (.hair, .hair),
        (.rv, .rv), (.stop, .stop), (.watch, .watch), (.ok, .ok), (.go, .go), (.agent, .agent),
    ]
    #expect(pairs.count == WorkspaceInk.Token.allCases.count)
    for background in [TerminalBackground.dark, .light] {
        let palette = TermPaint.Palette(depth: .truecolor, background: background)
        for (token, ink) in pairs {
            let hex = WorkspaceInk.hex(token, background: background)
            let expected = palette.ink(ink).rgb
            #expect(RGB24(red: UInt8(hex >> 16 & 0xFF), green: UInt8(hex >> 8 & 0xFF), blue: UInt8(hex & 0xFF))
                == expected, "\(token) on \(background)")
        }
    }
}
#endif
