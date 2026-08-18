import RVTheme

public struct BrowseState: Equatable, Sendable {
    public var rows: [String]
    public var selected: Int
    public var pageSize: Int
    public var quit: Bool

    public init(rows: [String], selected: Int = 0, pageSize: Int = 10, quit: Bool = false) {
        self.rows = rows
        self.selected = selected
        self.pageSize = max(1, pageSize)
        self.quit = quit
    }

    public var count: Int { rows.count }

    public var page: Int {
        guard pageSize > 0 else { return 0 }
        return selected / pageSize
    }
}

public enum BrowseEvent: Equatable, Sendable {
    case up
    case down
    case enter
    case quit
    case noop
}

public struct BrowseRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: BrowseState, palette: Palette) -> [String] {
        RVTUIRender.browse(model, palette: palette)
    }
}
