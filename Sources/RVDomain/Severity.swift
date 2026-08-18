public enum Severity: String, Sendable, Equatable {
    case low
    case medium
    case high
    case critical
}

extension Severity {
    public var blocksByDefault: Bool {
        self == .critical || self == .high
    }
}
