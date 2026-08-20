import RVTheme

enum CLIAppearance: Equatable, Sendable {
    case robot
    case pretty(Palette)

    /// Operator chrome for setup, service status, and later doctor.
    ///
    /// CI is robot even when `OutputMode` would still be pretty. Evaluate
    /// snapshots stay on `CommandRun` and do not use this door.
    static func resolve(probe: ThemeProbe, requested: RequestedMode) -> CLIAppearance {
        let mode = OutputMode(probe: probe, requested: requested)
        return resolved(
            mode: mode,
            ci: probe.ci,
            palette: Palette(for: ColorCapability(probe: probe, mode: mode))
        )
    }

    /// CI is one line, no circles. T2 `OutputMode` still maps CI+TTY browse to pretty.
    static func resolved(mode: OutputMode, ci: Bool, palette: Palette) -> CLIAppearance {
        if ci { return .robot }
        switch mode {
        case .robot:
            return .robot
        case .pretty, .browse:
            return .pretty(palette)
        }
    }
}

typealias SetupAppearance = CLIAppearance
