public enum OutputMode: Equatable, Sendable {
    case robot
    case pretty
    case browse

    /// Resolves pretty / robot / browse from a probe and a requested mode.
    /// Probe `forbid.json` / `forbid.robot` covers flags and env even when `requested` is `.automatic`.
    public init(probe: ThemeProbe, requested: RequestedMode) {
        if probe.forbid.json || probe.forbid.robot {
            self = .robot
            return
        }
        switch requested {
        case .robot:
            self = .robot
        case .browse:
            if probe.isBrowseEligible {
                self = .browse
            } else {
                self = probe.terminal.stdoutIsTTY ? .pretty : .robot
            }
        case .pretty:
            self = .pretty
        case .automatic:
            self = probe.terminal.stdoutIsTTY ? .pretty : .robot
        }
    }
}

public enum RequestedMode: Equatable, Sendable {
    case automatic
    case robot
    case pretty
    case browse
}

/// Spec name. Prefer `OutputMode(probe:requested:)`.
public func resolveOutputMode(probe: ThemeProbe, requested: RequestedMode) -> OutputMode {
    OutputMode(probe: probe, requested: requested)
}

/// Spec name. Prefer `probe.isBrowseEligible`.
public func browseEligible(_ probe: ThemeProbe) -> Bool {
    probe.isBrowseEligible
}
