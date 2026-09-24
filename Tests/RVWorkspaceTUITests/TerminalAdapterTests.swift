import Foundation
import Testing
@testable import RVWorkspaceTUI

@Test func textCursorColorClearAndCarriageReturn() {
    let terminal = SwiftTermAdapter(columns: 20, rows: 6)
    terminal.feed(Data("hello".utf8))
    #expect(terminal.frame().cells[0][0].text == "h")
    #expect(terminal.frame().cells[0][4].text == "o")
    #expect(terminal.frame().cursor == TerminalCursor(column: 5, row: 0))
    terminal.feed(Data("\u{1b}[1;4;31mX\u{1b}[0m".utf8))
    let painted = terminal.frame().cells[0][5]
    #expect(painted.text == "X")
    #expect(painted.bold)
    #expect(painted.underline)
    #expect(painted.foreground == TerminalColor(red: 205, green: 0, blue: 0))
    terminal.feed(Data("\u{1b}[44mB\u{1b}[38;5;202mC\u{1b}[0m".utf8))
    let background = terminal.frame().cells[0][6]
    #expect(background.background == TerminalColor(red: 0, green: 0, blue: 238))
    #expect(terminal.frame().cells[0][7].foreground == TerminalColor(red: 255, green: 95, blue: 0))
    terminal.feed(Data("\u{1b}[38;2;12;34;56mT\u{1b}[0m".utf8))
    #expect(terminal.frame().cells[0][8].foreground == TerminalColor(red: 12, green: 34, blue: 56))
    terminal.feed(Data("\r\nsecond".utf8))
    #expect(terminal.frame().line(1).hasPrefix("second"))
    terminal.feed(Data("\u{1b}[2J\u{1b}[H".utf8))
    #expect(terminal.frame().line(0).contains("hello") == false)
    terminal.feed(Data("ab\u{8}c".utf8))
    #expect(terminal.frame().line(0).hasPrefix("ac"))
    terminal.feed(Data("\u{1b}[?25l".utf8))
    #expect(terminal.frame().cursor == nil)
    terminal.feed(Data("\u{1b}[?25h".utf8))
    #expect(terminal.frame().cursor != nil)
}

@Test func splitUTF8IsNotDecodedAsTextBeforeTheEmulator() {
    let terminal = SwiftTermAdapter(columns: 10, rows: 2)
    let scalar = Array("é".utf8)
    #expect(scalar.count == 2)
    terminal.feed(Data([scalar[0]]))
    terminal.feed(Data([scalar[1]]))
    #expect(terminal.frame().cells[0][0].text == "é")
}

@Test func cursorAddressingUpdatesTheCellGrid() {
    let terminal = SwiftTermAdapter(columns: 12, rows: 4)
    terminal.feed(Data("\u{1b}[3;5Hpos".utf8))
    let frame = terminal.frame()
    #expect(frame.cells[2][4].text == "p")
    #expect(frame.cells[2][6].text == "s")
    #expect(frame.cursor == TerminalCursor(column: 7, row: 2))
}

@Test func inverseAndAlternateScreen() {
    let terminal = SwiftTermAdapter(columns: 10, rows: 4)
    terminal.feed(Data("\u{1b}[7mZ\u{1b}[0m".utf8))
    #expect(terminal.frame().cells[0][0].inverse)
    terminal.feed(Data("\u{1b}[?1049hALT\u{1b}[?1049l".utf8))
    #expect(terminal.frame().line(0).contains("ALT") == false)
    terminal.feed(Data("\u{1b}[?1049hALT".utf8))
    #expect(terminal.frame().line(0).contains("ALT"))
}

@Test func sustainedFeedKeepsTheFinalMarkerAndDropsTheOldestLines() {
    let terminal = SwiftTermAdapter(columns: 40, rows: 8)
    var payload = Data()
    for index in 0..<2_000 {
        payload.append(Data("line-\(index)\r\n".utf8))
    }
    payload.append(Data("FINAL-MARKER\r\n".utf8))
    let before = terminal.generation
    terminal.feed(payload)
    #expect(terminal.generation == before + 1)
    let screen = (0..<terminal.rows).map { terminal.frame().line($0) }.joined(separator: "\n")
    #expect(screen.contains("FINAL-MARKER"))
    #expect(screen.contains("line-0") == false)
    #expect(terminal.rows == 8)
    #expect(TerminalScrollback.lines == 1_000)
    #expect(TerminalScrollback.kittyImageCacheBytes == 0)
}
