import RVDomain

public protocol PatternEngine: Sendable {
    associatedtype Compiled: Sendable
    func compile(_ pattern: String) throws(PatternCompileError) -> Compiled
    func matches(_ compiled: Compiled, in text: String) -> Bool
    func firstMatch(_ compiled: Compiled, in text: String) -> Range<String.Index>?
    /// `firstMatch` bounded by `budget`, which the search charges. An
    /// engine that cannot finish within it returns `.exhausted`: a
    /// timed-out safe pattern never
    /// vouches, and a timed-out destructive pattern leaves the verdict
    /// indeterminate unless another rule denies.
    func search(_ compiled: Compiled, in text: String, budget: inout PatternBudget) -> PatternSearch
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

    /// Unbounded engines honor the budget between searches only.
    public func search(_ compiled: Compiled, in text: String, budget: inout PatternBudget) -> PatternSearch {
        guard budget.isSpent == false else { return .exhausted }
        let search = budget.beginSearch()
        defer { budget.finish(search) }
        return firstMatch(compiled, in: text).map(PatternSearch.match) ?? .noMatch
    }
}

public enum PatternCompileError: Error, Sendable, Equatable {
    case invalidPattern(name: String, message: String)
}
