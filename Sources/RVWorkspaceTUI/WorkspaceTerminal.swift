import Foundation

/// UI scrollback inside the terminal emulator.
///
/// The workspace host keeps a separate 64 KiB replay buffer so a later attach
/// can catch up. This limit is only the on-screen history. It is not written
/// to disk and it is not the reconnect buffer.
public enum TerminalScrollback {
    public static let lines = 1_000
    /// Remote runtimes do not need to ship terminal graphics into the local UI.
    public static let kittyImageCacheBytes = 0
}

public struct TerminalCell: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var underline: Bool
    public var inverse: Bool
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var italic: Bool
    public var dim: Bool
    public var strikethrough: Bool
    public var cursor: Bool

    public init(
        text: String,
        bold: Bool = false,
        underline: Bool = false,
        inverse: Bool = false,
        foreground: TerminalColor? = nil,
        background: TerminalColor? = nil,
        italic: Bool = false,
        dim: Bool = false,
        strikethrough: Bool = false,
        cursor: Bool = false
    ) {
        self.text = text
        self.bold = bold
        self.underline = underline
        self.inverse = inverse
        self.foreground = foreground
        self.background = background
        self.italic = italic
        self.dim = dim
        self.strikethrough = strikethrough
        self.cursor = cursor
    }
}

public struct TerminalCursor: Equatable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// Immutable, bounded view of a terminal's visible cells. The emulator is
/// read while the workspace model lock is held; renderers never touch it.
public struct TerminalFrame: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var cells: [[TerminalCell]]
    public var cursor: TerminalCursor?
    public var generation: Int

    public init(columns: Int, rows: Int, cells: [[TerminalCell]], cursor: TerminalCursor?, generation: Int) {
        self.columns = columns
        self.rows = rows
        self.cells = cells
        self.cursor = cursor
        self.generation = generation
    }

    public func line(_ row: Int) -> String {
        guard cells.indices.contains(row) else { return "" }
        return cells[row].map(\.text).joined()
    }
}

public struct TerminalColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// One emulator. Implementations must accept raw bytes, including split UTF-8.
public protocol TerminalEmulating: AnyObject {
    var columns: Int { get }
    var rows: Int { get }
    var generation: Int { get }
    func feed(_ bytes: Data)
    func resize(columns: Int, rows: Int)
    func frame() -> TerminalFrame
    func takeResponses() -> [Data]
}

public struct WorkspaceTerminalState: Equatable, Sendable {
    public var runtime: UUID
    public var title: String
    public var running: Bool
    public var exitStatus: Int32?
    public var lease: InputLease
    public var subscribed: Bool
    public var overflowed: Bool

    public init(
        runtime: UUID,
        title: String,
        running: Bool,
        exitStatus: Int32? = nil,
        lease: InputLease = .released,
        subscribed: Bool = false,
        overflowed: Bool = false
    ) {
        self.runtime = runtime
        self.title = title
        self.running = running
        self.exitStatus = exitStatus
        self.lease = lease
        self.subscribed = subscribed
        self.overflowed = overflowed
    }
}

public enum InputLease: Equatable, Sendable {
    case owned
    case readOnly
    case released
}
