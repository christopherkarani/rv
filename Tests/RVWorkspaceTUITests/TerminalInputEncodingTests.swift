import Foundation
import Testing
@testable import RVWorkspaceTUI

@Test func swiftTermInputModesFollowTerminalControlSequences() {
    let terminal = SwiftTermAdapter(columns: 80, rows: 24)
    #expect(terminal.inputModes == TerminalInputModes())
    terminal.feed(Data("\u{1b}[?1h\u{1b}[?2004h".utf8))
    #expect(terminal.inputModes == TerminalInputModes(applicationCursor: true, bracketedPaste: true))
    terminal.feed(Data("\u{1b}[?1l\u{1b}[?2004l".utf8))
    #expect(terminal.inputModes == TerminalInputModes())
}

@Test func terminalInputEncodingUsesApplicationCursorMode() {
    let normal = TerminalInputModes()
    let application = TerminalInputModes(applicationCursor: true)
    #expect(TerminalInputEncoding.bytes(for: .arrow(.up), modes: normal) == Data("\u{1b}[A".utf8))
    #expect(TerminalInputEncoding.bytes(for: .arrow(.up), modes: application) == Data("\u{1b}OA".utf8))
    #expect(TerminalInputEncoding.bytes(for: .home, modes: application) == Data("\u{1b}OH".utf8))
    #expect(TerminalInputEncoding.bytes(for: .alt(.arrow(.left)), modes: application) == Data("\u{1b}[1;3D".utf8))
}

@Test func terminalPasteRetainsUnicodeNewlinesAndModeFraming() {
    let content = "first\n二行\t👩‍💻"
    #expect(TerminalInputEncoding.paste(content, modes: TerminalInputModes()) == Data(content.utf8))
    #expect(TerminalInputEncoding.paste(content, modes: TerminalInputModes(bracketedPaste: true))
        == Data("\u{1b}[200~\(content)\u{1b}[201~".utf8))
}
