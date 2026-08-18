import RVPresentation
import RVTheme

public struct DenyRenderer: FrameRenderer {
    public init() {}

    public func render(_ model: DenyViewModel, palette: Palette) -> [String] {
        let blocked = paint("blocked", slot: palette.deny, reset: palette.reset)
        let header = "\(blocked)  \(model.command.rawValue)"
        let rule = paint(displayRuleID(model.ruleID), slot: palette.fact, reset: palette.reset)
        let body = "\(rule)  \(model.fact)"
        return wrapLine(header) + wrapLine(body) + wrapLine(model.nextAction)
    }
}

public func prettyAllowLines() -> [String] {
    ["allow"]
}
