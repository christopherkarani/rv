import RVPresentation
import RVTheme

/// Paints the three host slots. Only the circle uses `Palette`; text is unpainted.
public struct SetupRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: SetupViewModel, palette: Palette) -> [String] {
        if model.isQuiet { return [] }
        var lines: [String] = []
        for slot in model.slots {
            lines.append(row(slot, palette: palette))
        }
        lines.append(model.activity)
        lines.append(model.closerTitle)
        lines.append(model.closerNext)
        return lines
    }

    private func row(_ slot: SetupSlotView, palette: Palette) -> String {
        let filled = slot.kind == .wired
        let circle = filled ? "●" : "○"
        let ink = filled ? palette.heading : palette.muted
        let painted = paint(circle, slot: ink, reset: palette.reset)
        var line = "\(painted) \(slot.host.displayName)"
        if let clause = slot.clause, clause.isEmpty == false {
            line += "  \(clause)"
        }
        return line
    }
}
