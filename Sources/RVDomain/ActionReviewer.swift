public struct ReviewerProviderID: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RiskLevel: String, Sendable, Equatable, Codable {
    case low
    case medium
    case high
    case critical
}

public enum ReviewDecision: String, Sendable, Equatable, Codable {
    case allow
    case deny
    case abstain
}

public enum ReviewerConfidence: String, Sendable, Equatable, Codable {
    case low
    case medium
    case high

    public var isSufficientToAdvise: Bool {
        switch self {
        case .low:
            return false
        case .medium, .high:
            return true
        }
    }
}

public enum ReviewRationaleCategory: String, Sendable, Equatable, Codable {
    case allow
    case deny
    case abstain
    case uncertain
}

public enum ActionReviewerError: Error, Sendable, Equatable {
    case unsupported
    case timeout
}

public struct RepositoryReviewContext: Sendable, Equatable, Codable {
    public var name: String?
    public var currentBranch: String?

    /// True iff `currentBranch` is `main` or `master`.
    public var isSharedBranch: Bool {
        GitSharedBranch.contains(currentBranch)
    }

    public init(
        name: String? = nil,
        currentBranch: String? = nil
    ) {
        self.name = name
        self.currentBranch = currentBranch
    }
}

public struct EnvironmentReviewContext: Sendable, Equatable, Codable {
    public var labels: [String]
    public var isCI: Bool

    public init(labels: [String] = [], isCI: Bool = false) {
        self.labels = labels
        self.isCI = isCI
    }
}

/// Minimum repository and environment context. Credential-shaped values are stripped
/// when this context is wrapped in `ReviewRequest`.
public struct ReviewContext: Sendable, Equatable, Codable {
    public var repository: RepositoryReviewContext
    public var environment: EnvironmentReviewContext
    public var metadata: [String: String]

    public init(
        repository: RepositoryReviewContext,
        environment: EnvironmentReviewContext = EnvironmentReviewContext(),
        metadata: [String: String] = [:]
    ) {
        self.repository = repository
        self.environment = environment
        self.metadata = metadata
    }
}

public struct ReviewRequest: Sendable, Equatable, Codable {
    public let action: ProposedAction
    public let context: ReviewContext

    public init(action: ProposedAction, context: ReviewContext) {
        self.action = ReviewSanitizer.sanitize(action)
        self.context = ReviewSanitizer.sanitize(context)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(ProposedAction.self, forKey: .action)
        let context = try container.decode(ReviewContext.self, forKey: .context)
        self.init(action: action, context: context)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(context, forKey: .context)
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case context
    }
}

public enum ActionReviewBody: Sendable, Equatable, Codable {
    case aligned(ReviewDecision, category: ReviewRationaleCategory)
    case conflicting(decision: ReviewDecision, category: ReviewRationaleCategory)
}

public struct ActionReview: Sendable, Equatable, Codable {
    public var risk: RiskLevel
    public var confidence: ReviewerConfidence
    public var rationale: String
    public let body: ActionReviewBody

    public var decision: ReviewDecision {
        switch body {
        case .aligned(let decision, category: _),
             .conflicting(decision: let decision, category: _):
            return decision
        }
    }

    public var rationaleCategory: ReviewRationaleCategory {
        switch body {
        case .aligned(_, category: let category),
             .conflicting(decision: _, category: let category):
            return category
        }
    }

    /// Creates a review whose `body` is reclassified so a forged aligned
    /// pair such as `.aligned(.allow, category: .deny)` cannot persist.
    package init(
        risk: RiskLevel,
        confidence: ReviewerConfidence,
        rationale: String,
        body: ActionReviewBody
    ) {
        self.risk = risk
        self.confidence = confidence
        self.rationale = rationale
        switch body {
        case .aligned(let decision, category: let category),
             .conflicting(decision: let decision, category: let category):
            self.body = Self.classifiedBody(decision: decision, rationaleCategory: category)
        }
    }

    public init(
        decision: ReviewDecision,
        risk: RiskLevel,
        confidence: ReviewerConfidence,
        rationale: String,
        rationaleCategory: ReviewRationaleCategory
    ) {
        self = .make(
            decision: decision,
            risk: risk,
            confidence: confidence,
            rationale: rationale,
            rationaleCategory: rationaleCategory
        )
    }

    public static func make(
        decision: ReviewDecision,
        risk: RiskLevel,
        confidence: ReviewerConfidence,
        rationale: String,
        rationaleCategory: ReviewRationaleCategory
    ) -> ActionReview {
        ActionReview(
            risk: risk,
            confidence: confidence,
            rationale: rationale,
            body: classifiedBody(decision: decision, rationaleCategory: rationaleCategory)
        )
    }

    public var hasConflictingRationale: Bool {
        switch body {
        case .conflicting:
            return true
        case .aligned:
            return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decision = try container.decode(ReviewDecision.self, forKey: .decision)
        let risk = try container.decode(RiskLevel.self, forKey: .risk)
        let confidence = try container.decode(ReviewerConfidence.self, forKey: .confidence)
        let rationale = try container.decode(String.self, forKey: .rationale)
        let rationaleCategory = try container.decode(
            ReviewRationaleCategory.self,
            forKey: .rationaleCategory
        )
        self = .make(
            decision: decision,
            risk: risk,
            confidence: confidence,
            rationale: rationale,
            rationaleCategory: rationaleCategory
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encode(risk, forKey: .risk)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(rationaleCategory, forKey: .rationaleCategory)
    }

    private static func classifiedBody(
        decision: ReviewDecision,
        rationaleCategory: ReviewRationaleCategory
    ) -> ActionReviewBody {
        switch (decision, rationaleCategory) {
        case (.allow, .deny), (.deny, .allow):
            return .conflicting(decision: decision, category: rationaleCategory)
        default:
            return .aligned(decision, category: rationaleCategory)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case risk
        case confidence
        case rationale
        case rationaleCategory
    }
}

/// Provider-independent reviewer. Implementations live outside RVPolicy / RVEngine;
/// bind happens in `ReviewBind`.
public protocol ActionReviewer: Sendable {
    var providerID: ReviewerProviderID { get }
    func review(_ request: ReviewRequest) async throws -> ActionReview
}
