import RVDomain

public enum DecisionTone: Equatable, Sendable {
    case allow
    case deny
    case incomplete
}

public let explainHeading = "RV EXPLAIN"

public func decisionWord(_ decision: Decision) -> String {
    switch decision {
    case .allow:
        return "allow"
    case .deny:
        return "deny"
    case .indeterminate:
        return "incomplete"
    }
}

public func explainDecisionWord(_ decision: Decision) -> String {
    switch decision {
    case .allow:
        return "ALLOW"
    case .deny:
        return "DENY"
    case .indeterminate:
        return "INCOMPLETE"
    }
}

public func testResultWord(_ decision: Decision) -> String {
    switch decision {
    case .allow:
        return "ALLOWED"
    case .deny:
        return "BLOCKED"
    case .indeterminate:
        return "INCOMPLETE"
    }
}

public func decisionTone(_ decision: Decision) -> DecisionTone {
    switch decision {
    case .allow:
        return .allow
    case .deny:
        return .deny
    case .indeterminate:
        return .incomplete
    }
}
