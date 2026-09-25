#if os(macOS)
import Foundation
import SwiftTUICLI
import Testing
@testable import RVWorkspaceTUI

@Test func shiftedAndAltPrintableKeysReachTheFocusedTerminal() {
    #expect(TUIKeyDecoder.decodePrintable("A", modifiers: .shift) == .character("A"))
    #expect(TUIKeyDecoder.decodePrintable("?", modifiers: .shift) == .character("?"))
    #expect(TUIKeyDecoder.decodePrintable("a", modifiers: []) == .character("a"))
    #expect(TerminalInputEncoder.bytes(for: .alt(.character("b"))) == Data([0x1b, 0x62]))
}

@Test func controlGIsDecodedForTheWorkspacePrefix() {
    let press = KeyPress(.character("g"), modifiers: .ctrl)
    #expect(TUIKeyDecoder.decode(press) == .control("g"))
}
#endif
