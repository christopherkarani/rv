import RVTheme

enum CLIAppearance: Equatable, Sendable {
    case robot
    case pretty(Palette)

    /// Operator chrome for setup and service status.
    ///
    /// CI is robot even when `OutputMode` would still be pretty. Evaluate
    /// snapshots stay on `CommandRun` and do not use this door.
    static func resolve(json: Bool, robot: Bool, plain: Bool, noColor: Bool) -> CLIAppearance {
        resolve(
            probe: ThemeProbeFactory.live(
                jsonFlag: json,
                robotFlag: robot,
                plainFlag: plain,
                noColorFlag: noColor
            ),
            requested: OutputModeResolver.requested(json: json, robot: robot)
        )
    }

    static func resolve(probe: ThemeProbe, requested: RequestedMode) -> CLIAppearance {
        if probe.ci { return .robot }
        let mode = OutputMode(probe: probe, requested: requested)
        switch mode {
        case .robot:
            return .robot
        case .pretty, .browse:
            return .pretty(Palette(for: ColorCapability(probe: probe, mode: mode)))
        }
    }
}
