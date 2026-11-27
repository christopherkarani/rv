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

extension CLIAppearance {
    /// The pretty palette, or no color when output is piped or robot.
    var palette: Palette {
        switch self {
        case .robot: return colorOffPalette
        case .pretty(let palette): return palette
        }
    }
}
