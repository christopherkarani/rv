import RVDomain

public protocol PatternEngine: Sendable {
    associatedtype Compiled: Sendable
    func compile(_ pattern: String) throws(PatternCompileError) -> Compiled
    func matches(_ compiled: Compiled, in text: String) -> Bool
    func firstMatch(_ compiled: Compiled, in text: String) -> Range<String.Index>?
    /// `firstMatch` bounded by `deadline`. An engine that cannot finish in
    /// time returns `.exhausted`, which the gate treats as indeterminate:
    /// a timed-out safe pattern never vouches, a timed-out destructive
    /// pattern never passes.
    func search(_ compiled: Compiled, in text: String, deadline: ContinuousClock.Instant) -> PatternSearch
}

/// Outcome of one bounded pattern search.
public enum PatternSearch: Sendable, Equatable {
    case match(Range<String.Index>)
    case noMatch
    case exhausted
}

extension PatternEngine {
    public func matches(_ compiled: Compiled, in text: String) -> Bool {
        firstMatch(compiled, in: text) != nil
    }

    /// Unbounded engines honor the deadline between searches only.
    public func search(_ compiled: Compiled, in text: String, deadline: ContinuousClock.Instant) -> PatternSearch {
        guard ContinuousClock.now < deadline else { return .exhausted }
        return firstMatch(compiled, in: text).map(PatternSearch.match) ?? .noMatch
    }
}

public enum PatternCompileError: Error, Sendable, Equatable {
    case invalidPattern(name: String, message: String)
}
