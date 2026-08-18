import RVDomain

public protocol PatternEngine: Sendable {
    associatedtype Compiled: Sendable
    func compile(_ pattern: String) throws -> Compiled
    func matches(_ compiled: Compiled, in text: String) -> Bool
}

public enum PatternCompileError: Error, Sendable, Equatable {
    case invalidPattern(name: String, message: String)
}
