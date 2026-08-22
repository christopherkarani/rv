import RVDomain

public protocol PatternEngine: Sendable {
    associatedtype Compiled: Sendable
    func compile(_ pattern: String) throws(PatternCompileError) -> Compiled
    func matches(_ compiled: Compiled, in text: String) -> Bool
    func firstMatch(_ compiled: Compiled, in text: String) -> Range<String.Index>?
}

extension PatternEngine {
    public func matches(_ compiled: Compiled, in text: String) -> Bool {
        firstMatch(compiled, in: text) != nil
    }
}

public enum PatternCompileError: Error, Sendable, Equatable {
    case invalidPattern(name: String, message: String)
}
