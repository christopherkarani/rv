import Foundation
import SwiftTerm

/// SwiftTerm's terminal model. It accepts bytes from Workspace Host and owns
/// neither a local process nor a PTY.
public final class SwiftTermAdapter: TerminalEmulating {
    private let terminal: Terminal
    private let delegate: TerminalDelegateProxy
    private var pendingResponses: [Data] = []
    private var pendingResponseBytes = 0
    private var cursorVisible = true
    public private(set) var generation = 0

    public init(columns: Int, rows: Int) {
        let delegate = TerminalDelegateProxy()
        let options = TerminalOptions(
            cols: Self.bound(columns),
            rows: Self.bound(rows),
            termName: "xterm-256color",
            scrollback: TerminalScrollback.lines,
            enableSixelReported: false,
            kittyImageCacheLimitBytes: TerminalScrollback.kittyImageCacheBytes,
            ansi256PaletteStrategy: .xterm
        )
        self.delegate = delegate
        self.terminal = Terminal(delegate: delegate, options: options)
        delegate.sendBytes = { [weak self] bytes in self?.recordResponse(bytes) }
        delegate.cursorVisibility = { [weak self] visible in self?.cursorVisible = visible }
    }

    public var columns: Int { terminal.cols }
    public var rows: Int { terminal.rows }

    public func feed(_ bytes: Data) {
        guard bytes.isEmpty == false else { return }
        terminal.feed(byteArray: Array(bytes))
        generation += 1
    }

    public func resize(columns: Int, rows: Int) {
        let columns = Self.bound(columns)
        let rows = Self.bound(rows)
        guard columns != terminal.cols || rows != terminal.rows else { return }
        terminal.resize(cols: columns, rows: rows)
        generation += 1
    }

    public func frame() -> TerminalFrame {
        let cursorLocation = terminal.getCursorLocation()
        let cursor = cursorVisible
            && cursorLocation.x >= 0 && cursorLocation.x < terminal.cols
            && cursorLocation.y >= 0 && cursorLocation.y < terminal.rows
            ? TerminalCursor(column: cursorLocation.x, row: cursorLocation.y)
            : nil
        let cells = (0..<terminal.rows).map { row in
            (0..<terminal.cols).map { column -> TerminalCell in
                guard let data = terminal.getCharData(col: column, row: row) else {
                    return TerminalCell(text: " ")
                }
                let style = data.attribute.style
                let text = data.width == 0 ? "" : String(terminal.getCharacter(for: data))
                return TerminalCell(
                    text: text,
                    bold: style.contains(.bold),
                    underline: style.contains(.underline),
                    inverse: style.contains(.inverse),
                    foreground: Self.color(data.attribute.fg),
                    background: Self.color(data.attribute.bg),
                    italic: style.contains(.italic),
                    dim: style.contains(.dim),
                    strikethrough: style.contains(.crossedOut),
                    cursor: cursor?.column == column && cursor?.row == row
                )
            }
        }
        return TerminalFrame(
            columns: terminal.cols,
            rows: terminal.rows,
            cells: cells,
            cursor: cursor,
            generation: generation
        )
    }

    /// Terminal replies (for device and size queries) are returned to the model
    /// after `feed` completes so WorkspaceClient I/O never runs from inside the
    /// SwiftTerm delegate callback.
    public func takeResponses() -> [Data] {
        defer {
            pendingResponses.removeAll(keepingCapacity: true)
            pendingResponseBytes = 0
        }
        return pendingResponses
    }

    fileprivate func recordResponse(_ bytes: ArraySlice<UInt8>) {
        guard bytes.isEmpty == false,
              bytes.count <= Self.maximumQueuedResponseBytes - pendingResponseBytes else { return }
        let response = Data(bytes)
        pendingResponses.append(response)
        pendingResponseBytes += response.count
    }

    private static let maximumQueuedResponseBytes = 64 * 1024

    private static func bound(_ value: Int) -> Int {
        min(512, max(1, value))
    }

    private static func color(_ color: Attribute.Color) -> TerminalColor? {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return nil
        case .ansi256(let code):
            let value = Int(code)
            let rgb: (UInt8, UInt8, UInt8)
            if value < ansiColors.count {
                rgb = ansiColors[value]
            } else if value < 232 {
                let index = value - 16
                rgb = (
                    Self.cubeLevels[index / 36],
                    Self.cubeLevels[(index / 6) % 6],
                    Self.cubeLevels[index % 6]
                )
            } else {
                let gray = UInt8(8 + (value - 232) * 10)
                rgb = (gray, gray, gray)
            }
            return TerminalColor(red: rgb.0, green: rgb.1, blue: rgb.2)
        case .trueColor(let red, let green, let blue):
            return TerminalColor(red: red, green: green, blue: blue)
        }
    }

    /// 6x6x6 color cube levels for ANSI 16-231. Shared so `frame` does not
    /// allocate per cell.
    private static let cubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]

    /// The standard xterm palette used by SwiftTerm's `.xterm` strategy.
    private static let ansiColors: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
        (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]
}

private final class TerminalDelegateProxy: TerminalDelegate {
    var sendBytes: ((ArraySlice<UInt8>) -> Void)?
    var cursorVisibility: ((Bool) -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sendBytes?(data)
    }

    func isProcessTrusted(source: Terminal) -> Bool {
        false
    }

    func showCursor(source: Terminal) {
        cursorVisibility?(true)
    }

    func hideCursor(source: Terminal) {
        cursorVisibility?(false)
    }
}

public struct SwiftTermFactory: TerminalEmulatorFactory, Sendable {
    public init() {}

    public func make(columns: Int, rows: Int) -> any TerminalEmulating {
        SwiftTermAdapter(columns: columns, rows: rows)
    }
}

public protocol TerminalEmulatorFactory: Sendable {
    func make(columns: Int, rows: Int) -> any TerminalEmulating
}
