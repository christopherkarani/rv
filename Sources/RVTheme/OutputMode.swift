public enum OutputMode: Equatable, Sendable {
    case robot
    case pretty
    case browse
}

public enum RequestedMode: Equatable, Sendable {
    case automatic
    case robot
    case pretty
    case browse
}

public func resolveOutputMode(probe: ThemeProbe, requested: RequestedMode) -> OutputMode {
    if probe.jsonFlag || probe.robotFlag || requested == .robot {
        return .robot
    }
    switch requested {
    case .robot:
        return .robot
    case .browse:
        if browseEligible(probe) {
            return .browse
        }
        return probe.stdoutIsTTY ? .pretty : .robot
    case .pretty:
        return .pretty
    case .automatic:
        return probe.stdoutIsTTY ? .pretty : .robot
    }
}

public func browseEligible(_ probe: ThemeProbe) -> Bool {
    probe.stdinIsTTY
        && probe.stdoutIsTTY
        && !probe.jsonFlag
        && !probe.robotFlag
        && !probe.plainFlag
        && !probe.ci
        && !probe.noColorEnv
}
