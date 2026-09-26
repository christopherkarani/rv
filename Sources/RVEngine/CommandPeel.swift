import RVDomain

/// Matching-view grant key plus innermost executing command from one peel.
public enum CommandPeel: Sendable, Equatable {
    case complete(matching: MatchingView, executing: ExecutingCommand, layers: [WrapperKind])
    case limited(matching: MatchingView, layers: [WrapperKind])
}

/// One peel entry. `matchingView` stays the outer grant key; `executing` is
/// the unwrapped inner command analyzers consume.
///
/// Thin adapter: both entries delegate to the single `ShellPipeline.parse`.
public enum CommandPeelCore {
    public static func matchingView(of command: String) -> MatchingView {
        ShellPipeline.parse(command).matching
    }

    public static func peel(_ command: ShellCommand) -> CommandPeel {
        let parsed = ShellPipeline.parse(command.rawValue)
        if let executing = parsed.executing {
            return .complete(
                matching: parsed.matching,
                executing: executing,
                layers: parsed.layers
            )
        }
        return .limited(matching: parsed.matching, layers: parsed.layers)
    }
}
