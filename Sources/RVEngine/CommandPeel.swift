import RVDomain

/// Matching-view grant key plus innermost executing command from one peel.
public enum CommandPeel: Sendable, Equatable {
    case complete(matching: MatchingView, executing: ExecutingCommand, layers: [WrapperKind])
    case limited(matching: MatchingView, layers: [WrapperKind])
}

/// One peel entry. `matchingView` stays the outer grant key; `executing` is
/// the unwrapped inner command analyzers consume.
public enum CommandPeelCore {
    public static func matchingView(of command: String) -> MatchingView {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return MatchingView("") }
        var current = applyRoleAwareQuotes(maskNonExecutingHeredocBodies(trimmed))
        var iteration = 0
        while iteration < Normalize.maxWrapperIterations {
            iteration += 1
            if let stripped = stripSudo(current) {
                current = stripped
                continue
            }
            if let stripped = stripEnv(current) {
                current = stripped
                continue
            }
            if let stripped = stripCommandWrapper(current) {
                current = stripped
                continue
            }
            if let stripped = stripLeadingBackslash(current) {
                current = stripped
                continue
            }
            break
        }
        return MatchingView(stripAbsolutePathOnArgv0(current))
    }

    public static func peel(_ command: ShellCommand) -> CommandPeel {
        let matching = matchingView(of: command.rawValue)
        switch unwrapCommand(command) {
        case .complete(let inner):
            return .complete(
                matching: matching,
                executing: inner.executing,
                layers: inner.layers
            )
        case .limited(let layers):
            return .limited(matching: matching, layers: layers)
        }
    }
}
