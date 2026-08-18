public struct ShellCommand: RawRepresentable, Hashable, Sendable, Equatable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
