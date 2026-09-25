import Foundation

/// Remembers the last size sent to one runtime and holds a newer size until it is stable.
public struct ResizeCoalescer: Equatable, Sendable {
    public var lastSentRows: Int?
    public var lastSentColumns: Int?
    public var pendingRows: Int?
    public var pendingColumns: Int?
    public var pendingAt: Date?

    public static let settle: TimeInterval = 0.05
    public static let minimum = 1
    public static let maximum = 512

    public init() {}

    /// Returns a size only when it differs from the last send and has stayed unchanged for `settle`.
    public mutating func propose(rows: Int, columns: Int, now: Date) -> (rows: Int, columns: Int)? {
        let nextRows = min(Self.maximum, max(Self.minimum, rows))
        let nextColumns = min(Self.maximum, max(Self.minimum, columns))
        if lastSentRows == nextRows, lastSentColumns == nextColumns {
            pendingRows = nil
            pendingColumns = nil
            pendingAt = nil
            return nil
        }
        if pendingRows != nextRows || pendingColumns != nextColumns {
            pendingRows = nextRows
            pendingColumns = nextColumns
            pendingAt = now
            return nil
        }
        guard let pendingAt, now.timeIntervalSince(pendingAt) >= Self.settle else { return nil }
        lastSentRows = nextRows
        lastSentColumns = nextColumns
        self.pendingRows = nil
        self.pendingColumns = nil
        self.pendingAt = nil
        return (nextRows, nextColumns)
    }

    public mutating func recordLaunch(rows: Int, columns: Int) {
        lastSentRows = min(Self.maximum, max(Self.minimum, rows))
        lastSentColumns = min(Self.maximum, max(Self.minimum, columns))
        pendingRows = nil
        pendingColumns = nil
        pendingAt = nil
    }

    /// Terminal dimensions most recently requested by layout, including a
    /// change still waiting for its debounce window.
    public var effectiveSize: (rows: Int, columns: Int)? {
        guard let rows = pendingRows ?? lastSentRows,
              let columns = pendingColumns ?? lastSentColumns else { return nil }
        return (rows, columns)
    }

    /// A call made by the render loop only records geometry. RPCs happen from
    /// the workspace model's coalescing tick, never while building a view.
    /// This never promotes a settled size: promoting here would mark the size
    /// sent while `flush` still holds nothing, silently dropping the resize.
    public mutating func record(rows: Int, columns: Int, now: Date) {
        let nextRows = min(Self.maximum, max(Self.minimum, rows))
        let nextColumns = min(Self.maximum, max(Self.minimum, columns))
        if lastSentRows == nextRows, lastSentColumns == nextColumns {
            pendingRows = nil
            pendingColumns = nil
            pendingAt = nil
            return
        }
        if pendingRows != nextRows || pendingColumns != nextColumns {
            pendingRows = nextRows
            pendingColumns = nextColumns
            pendingAt = now
        }
    }

    public mutating func flush(now: Date) -> (rows: Int, columns: Int)? {
        guard let rows = pendingRows, let columns = pendingColumns else { return nil }
        return propose(rows: rows, columns: columns, now: now)
    }
}
