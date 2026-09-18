/// Innermost command after wrapper peel. Distinct from raw `ShellCommand`
/// and from the outer grant key `MatchingView`.
public struct ExecutingCommand: RawRepresentable, Hashable, Sendable, Equatable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
