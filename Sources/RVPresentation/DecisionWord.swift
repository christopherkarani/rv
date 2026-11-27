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
            CommandVocabulary.Verdict.allow
        case .deny:
            CommandVocabulary.Verdict.deny
        case .indeterminate:
            CommandVocabulary.Verdict.incomplete
        }
    }

    /// Uppercase decision word for explain headings.
    public var emphasizedName: String {
        displayName.uppercased()
    }

    /// Test-result word painted on the test frame.
    public var testResultName: String {
        switch self {
        case .allow:
            CommandVocabulary.Verdict.allowed.uppercased()
        case .deny:
            CommandVocabulary.Verdict.blocked.uppercased()
        case .indeterminate:
            CommandVocabulary.Verdict.incomplete.uppercased()
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
