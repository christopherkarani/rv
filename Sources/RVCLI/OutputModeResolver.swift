import RVTheme

enum OutputModeResolver {
    static func resolve(probe: ThemeProbe, requested: RequestedMode) -> OutputMode {
        resolveOutputMode(probe: probe, requested: requested)
    }

    static func requested(json: Bool, robot: Bool) -> RequestedMode {
        if json || robot { return .robot }
        return .automatic
    }
}
