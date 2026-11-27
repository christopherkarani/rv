import Foundation

/// The role a piece of text plays on screen, named as the v5c mock names
/// its palette. The command maps each to a colour for the terminal's depth
/// and background; with no colour they are plain text.
public enum TermInk: Equatable, Sendable {
    /// Body text and the headline.
    case fg
    /// Secondary text: a command that ran.
    case soft
    /// Supporting text: the sentence under the headline, the river.
    case mute
    /// Hints, times, axes.
    case ghost
    /// Card and sheet borders.
    case hair
    /// The ◆ mark and the current tab's digit.
    case rv
    /// ✕ and "stopped".
    case stop
    /// ◐ and "watching".
    case watch
    /// ● and "guarding".
    case ok
    /// Keys you can press.
    case go
    /// ⏺ and agent names.
    case agent
}

/// A cell background: the current tab and row, a card, the mode pill.
public enum TermFill: Equatable, Sendable {
    case sel
    case panel
    case watch
    case ok
    case stop
}

/// A run of text with one look.
public struct TermSpan: Equatable, Sendable {
    public var text: String
    public var ink: TermInk
    public var bold: Bool
    public var fill: TermFill?
    /// Under a sheet: drawn faded toward the background.
    public var faded: Bool

    public init(_ text: String, _ ink: TermInk = .fg, bold: Bool = false, fill: TermFill? = nil, faded: Bool = false) {
        self.text = text
        self.ink = ink
        self.bold = bold
        self.fill = fill
        self.faded = faded
    }
}

/// One screen line, at most the screen's width in characters.
public typealias TermLine = [TermSpan]

/// A grid of cells the views draw into, the way the mock's `Screen` does,
/// so a card, a tab or a sheet can sit at any column. `lines` turns it
/// back into spans, trailing blanks trimmed.
struct TermCanvas {
    struct Cell: Equatable {
        var char: Character = " "
        var ink: TermInk = .fg
        var bold = false
        var fill: TermFill?
        var faded = false
    }

    let width: Int
    let height: Int
    private var cells: [Cell]

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        cells = Array(repeating: Cell(), count: self.width * self.height)
    }

    /// Writes `text` from column `x`; returns the column after it. Cells off
    /// the grid are skipped. A nil `fill` keeps the background underneath.
    @discardableResult
    mutating func put(_ x: Int, _ y: Int, _ text: String, _ ink: TermInk = .fg, bold: Bool = false, fill: TermFill? = nil) -> Int {
        var column = x
        for char in text {
            if y >= 0, y < height, column >= 0, column < width {
                let index = y * width + column
                let under = cells[index].fill
                cells[index] = Cell(char: char, ink: ink, bold: bold, fill: fill ?? under)
            }
            column += 1
        }
        return column
    }

    /// Writes spans one after another from `x`, cutting the last that would
    /// pass `x + limit` with "…". Returns the column after the last.
    @discardableResult
    mutating func segs(_ x: Int, _ y: Int, _ spans: [TermSpan], limit: Int? = nil) -> Int {
        let end = limit.map { x + $0 } ?? width
        var column = x
        for span in spans {
            guard column < end else { break }
            var text = span.text
            if column + text.count > end { text = String(text.prefix(max(0, end - column - 1))) + "…" }
            column = put(column, y, text, span.ink, bold: span.bold, fill: span.fill)
        }
        return column
    }

    /// Writes spans centred on column `center`.
    @discardableResult
    mutating func center(_ center: Int, _ y: Int, _ spans: [TermSpan]) -> Int {
        let length = spans.reduce(0) { $0 + $1.text.count }
        return segs(max(0, center - length / 2), y, spans)
    }

    /// Blanks a rectangle onto `fill`.
    mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fill: TermFill?) {
        for row in y..<(y + max(0, h)) where row >= 0 && row < height {
            for column in x..<(x + max(0, w)) where column >= 0 && column < width {
                cells[row * width + column] = Cell(fill: fill)
            }
        }
    }

    /// A rounded box, optionally filled.
    mutating func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ink: TermInk = .hair, fill: TermFill? = nil) {
        guard w >= 2, h >= 2 else { return }
        if let fill { self.fill(x, y, w, h, fill) }
        put(x, y, "╭" + String(repeating: "─", count: w - 2) + "╮", ink, fill: fill)
        for row in (y + 1)..<(y + h - 1) {
            put(x, row, "│", ink, fill: fill)
            put(x + w - 1, row, "│", ink, fill: fill)
        }
        put(x, y + h - 1, "╰" + String(repeating: "─", count: w - 2) + "╯", ink, fill: fill)
    }

    /// Fades everything drawn so far, for a sheet laid over it.
    mutating func fadeAll() {
        for index in cells.indices { cells[index].faded = true }
    }

    /// The grid as lines of spans, each line's trailing plain blanks dropped.
    func lines() -> [TermLine] {
        (0..<height).map { row in
            let slice = cells[(row * width)..<((row + 1) * width)]
            var end = slice.endIndex
            while end > slice.startIndex, slice[end - 1].char == " ", slice[end - 1].fill == nil { end -= 1 }
            var line: TermLine = []
            for cell in slice[slice.startIndex..<end] {
                let blank = cell.char == " "
                if var last = line.last,
                    last.fill == cell.fill, last.faded == cell.faded,
                    blank || (last.ink == cell.ink && last.bold == cell.bold)
                {
                    last.text.append(cell.char)
                    line[line.count - 1] = last
                } else {
                    line.append(TermSpan(String(cell.char), cell.ink, bold: cell.bold, fill: cell.fill, faded: cell.faded))
                }
            }
            return line
        }
    }
}
