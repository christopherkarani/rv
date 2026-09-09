/// Shareable compiled-rule document. English is provenance, not a matcher.
public struct PolicyDocument: Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var rules: [PolicyDocumentRule]

    public init(schemaVersion: Int = currentSchemaVersion, rules: [PolicyDocumentRule] = []) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }

    public func typedRules(origin: TypedRuleOrigin) -> [TypedRule] {
        rules.map { $0.typedRule(origin: origin) }
    }
}

/// One compiled row. `english` is optional provenance and is dropped at match time.
public struct PolicyDocumentRule: Sendable, Equatable, Codable {
    public var id: RuleID
    public var verdict: TypedRuleVerdict
    public var predicate: PolicyPredicate
    public var english: String?

    public init(
        id: RuleID,
        verdict: TypedRuleVerdict,
        predicate: PolicyPredicate,
        english: String? = nil
    ) {
        self.id = id
        self.verdict = verdict
        self.predicate = predicate
        self.english = Self.normalizedEnglish(english)
    }

    public func typedRule(origin: TypedRuleOrigin) -> TypedRule {
        TypedRule(id: id, predicate: predicate, verdict: verdict, origin: origin)
    }

    public static func normalizedEnglish(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

extension PackID {
    public static let typedGit = PackID(rawValue: "typed.git")
}
