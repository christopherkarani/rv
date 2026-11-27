#if os(macOS)
import SwiftTUICLI
import Testing
@testable import RVWorkspaceTUI

@Test func inkUsesRvsTerminalPaletteOnDark() {
    #expect(WorkspaceInk.hex(.rv, background: .dark) == 0xB8A9FF)
    #expect(WorkspaceInk.hex(.watch, background: .dark) == 0xFFCF6B)
    #expect(WorkspaceInk.hex(.stop, background: .dark) == 0xFF7A7A)
    #expect(WorkspaceInk(background: .dark).watch == Color(hexRGB: 0xFFCF6B))
}

@Test func lightInkReplacesEveryToken() {
    for token in WorkspaceInk.Token.allCases {
        #expect(WorkspaceInk.hex(token, background: .light) != WorkspaceInk.hex(token, background: .dark), "\(token)")
    }
}

@Test func tonesMapToTheirTokens() {
    let ink = WorkspaceInk(background: .dark)
    #expect(ink.color(.quiet) == ink.mute)
    #expect(ink.color(.ok) == ink.ok)
    #expect(ink.color(.wants) == ink.watch)
    #expect(ink.color(.stopped) == ink.stop)
}
#endif
