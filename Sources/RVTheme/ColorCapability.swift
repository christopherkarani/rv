public struct ColorCapability: Equatable, Sendable {
    public var colorsEnabled: Bool

    public init(colorsEnabled: Bool) {
        self.colorsEnabled = colorsEnabled
    }
}

public func colorCapability(probe: ThemeProbe, mode: OutputMode) -> ColorCapability {
    if mode == .robot {
        return ColorCapability(colorsEnabled: false)
    }
    if probe.ci || probe.noColorEnv || probe.plainFlag || probe.noColorFlag || probe.termDumb {
        return ColorCapability(colorsEnabled: false)
    }
    if !probe.stdoutIsTTY {
        return ColorCapability(colorsEnabled: false)
    }
    return ColorCapability(colorsEnabled: true)
}
