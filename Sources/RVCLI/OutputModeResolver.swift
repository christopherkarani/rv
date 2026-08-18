import RVTheme

enum OutputModeResolver {
    static func requested(json: Bool, robot: Bool) -> RequestedMode {
        if json || robot { return .robot }
        return .automatic
    }
}
