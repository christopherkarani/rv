import RVPresentation
import RVTheme

public struct PacksRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: PacksViewModel, palette: Palette) -> [String] {
        let width = model.rows.map(\.id.rawValue.count).max() ?? 0
        return model.rows.flatMap { row in
            let id = padRight(row.id.rawValue, to: width)
            let flag = row.enabled ? "on" : "off"
            let painted = paint(flag, slot: row.enabled ? palette.allow : palette.muted, reset: palette.reset)
            return wrapLine("\(id)  \(painted)")
        }
    }
}
