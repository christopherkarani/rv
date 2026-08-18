public struct NamedPattern: Sendable, Equatable {
    public var name: String
    public var pattern: String

    public init(name: String, pattern: String) {
        self.name = name
        self.pattern = pattern
    }
}

public struct DestructiveRule: Sendable, Equatable {
    public var name: String
    public var pattern: String
    public var severity: Severity
    public var reason: String
    public var explanation: String?

    public init(
        name: String,
        pattern: String,
        severity: Severity,
        reason: String,
        explanation: String? = nil
    ) {
        self.name = name
        self.pattern = pattern
        self.severity = severity
        self.reason = reason
        self.explanation = explanation
    }
}

public struct PackSnapshot: Sendable, Equatable {
    public var id: PackID
    public var name: String
    public var description: String
    public var keywords: [String]
    public var safe: [NamedPattern]
    public var destructive: [DestructiveRule]

    public init(
        id: PackID,
        name: String,
        description: String,
        keywords: [String],
        safe: [NamedPattern],
        destructive: [DestructiveRule]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.keywords = keywords
        self.safe = safe
        self.destructive = destructive
    }
}
