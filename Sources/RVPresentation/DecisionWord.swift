import RVDomain

public enum DecisionTone: Equatable, Sendable {
    case allow
    case deny
    case incomplete
}

package let explainHeading = "RV EXPLAIN"

extension Decision {
    /// Lowercase operator word for explain body copy.
    public var displayName: String {
        switch self {
        case .allow:
            "allow"
        case .deny:
            "deny"
        case .indeterminate:
            "incomplete"
        }
    }

    /// Uppercase decision word for explain headings.
    public var emphasizedName: String {
        switch self {
        case .allow:
            "ALLOW"
        case .deny:
            "DENY"
        case .indeterminate:
            "INCOMPLETE"
        }
    }

    /// Test-result word painted on the test frame.
    public var testResultName: String {
        switch self {
        case .allow:
            "ALLOWED"
        case .deny:
            "BLOCKED"
        case .indeterminate:
            "INCOMPLETE"
        }
    }

    /// Palette slot for this decision.
    public var tone: DecisionTone {
        switch self {
        case .allow:
            .allow
        case .deny:
            .deny
        case .indeterminate:
            .incomplete
        }
    }
}

package func decisionWord(_ decision: Decision) -> String {
    decision.displayName
}

public func explainDecisionWord(_ decision: Decision) -> String {
    decision.emphasizedName
}

package func testResultWord(_ decision: Decision) -> String {
    decision.testResultName
}

public func decisionTone(_ decision: Decision) -> DecisionTone {
    decision.tone
}
