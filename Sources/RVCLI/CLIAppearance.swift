import RVTheme

enum CLIAppearance: Equatable, Sendable {
    case robot
    case pretty(Palette)

    static func resolve(json: Bool, robot: Bool, plain: Bool, noColor: Bool) -> CLIAppearance {
        CommandContext.resolveAppearance(json: json, robot: robot, plain: plain, noColor: noColor)
    }

    static func resolve(probe: ThemeProbe, requested: RequestedMode) -> CLIAppearance {
        CommandContext.resolveAppearance(probe: probe, requested: requested)
    }
}
