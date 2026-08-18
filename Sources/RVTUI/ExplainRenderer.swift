import RVPresentation
import RVTheme

public struct ExplainRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: ExplainViewModel, palette: Palette) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: wrapLine(paint(model.fact, slot: palette.fact, reset: palette.reset)))
        if let next = model.nextAction {
            lines.append(contentsOf: wrapLine(next))
        }
        for step in model.steps {
            let name = paint(padRight(step.name, to: 14), slot: palette.muted, reset: palette.reset)
            lines.append(contentsOf: wrapLine("\(name)\(step.outcome)"))
        }
        return lines
    }
}
