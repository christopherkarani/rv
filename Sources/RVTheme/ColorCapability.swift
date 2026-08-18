public struct ColorCapability: Equatable, Sendable {
    public var colorsEnabled: Bool

    public init(colorsEnabled: Bool) {
        self.colorsEnabled = colorsEnabled
    }

    /// Robot never has color. Plain, CI, color-off, or a non-TTY stdout also kill it.
    public init(probe: ThemeProbe, mode: OutputMode) {
        if mode == .robot {
            self.init(colorsEnabled: false)
            return
        }
        self.init(colorsEnabled: probe.forbid.canCarryColor && probe.terminal.canCarryColor)
    }
}

/// Spec name until T9. Prefer `ColorCapability(probe:mode:)`.
public func colorCapability(probe: ThemeProbe, mode: OutputMode) -> ColorCapability {
    ColorCapability(probe: probe, mode: mode)
}
