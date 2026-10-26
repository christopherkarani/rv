import Foundation
import Testing
@testable import SwiftTerm

@Test func historyViewportReportsAbsoluteRetainedRangeAcrossTrimAndAlternateScreen() {
    let terminal = Terminal(
        delegate: TerminalTestDelegate(),
        options: TerminalOptions(cols: 8, rows: 3, scrollback: 2)
    )
    let initial = terminal.historyViewport
    #expect(initial.oldestLine == 0)
    #expect(initial.liveTopLine == 0)
    #expect(initial.retainedLineCount == 3)
    #expect(initial.rows == 3)
    #expect(initial.isAlternate == false)

    terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")
    let trimmed = terminal.historyViewport
    #expect(trimmed.oldestLine > 0)
    #expect(trimmed.liveTopLine >= trimmed.oldestLine)
    #expect(trimmed.retainedLineCount == 5)
    #expect(terminal.getScrollInvariantLine(row: trimmed.oldestLine) != nil)
    #expect(terminal.getScrollInvariantLine(row: trimmed.oldestLine - 1) == nil)
    #expect(terminal.getScrollInvariantLine(row: trimmed.liveTopLine + 2) != nil)

    terminal.feed(text: "\u{1b}[?1049h")
    let alternate = terminal.historyViewport
    #expect(alternate.isAlternate)
    #expect(alternate.oldestLine == 0)
    #expect(alternate.liveTopLine == 0)
    #expect(alternate.retainedLineCount == 3)
}
