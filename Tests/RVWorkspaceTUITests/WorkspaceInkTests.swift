#if os(macOS)
import SwiftTUICLI
import Testing
@testable import RVWorkspaceTUI

@Test func darkInkKeepsTheShellsNamedColors() {
    let dark = WorkspaceInk(background: .dark)
    #expect(dark.attention == .yellow)
    #expect(dark.ok == .green)
    #expect(dark.muted == .gray)
    #expect(dark.danger == .red)
}

@Test func lightInkReplacesEveryChromeColor() {
    let dark = WorkspaceInk(background: .dark)
    let light = WorkspaceInk(background: .light)
    #expect(light.attention != dark.attention)
    #expect(light.ok != dark.ok)
    #expect(light.muted != dark.muted)
    #expect(light.danger != dark.danger)
}
#endif
