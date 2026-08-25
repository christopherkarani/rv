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
    public var isSharedBranch: Bool

    public init(
        name: String? = nil,
        currentBranch: String? = nil,
        isSharedBranch: Bool = false
    ) {
        self.name = name
        self.currentBranch = currentBranch
        self.isSharedBranch = isSharedBranch
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
    public var action: ProposedAction
    public var context: ReviewContext

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

public struct ActionReview: Sendable, Equatable, Codable {
    public var decision: ReviewDecision
    public var risk: RiskLevel
    public var confidence: ReviewerConfidence
    public var rationale: String
    public var rationaleCategory: ReviewRationaleCategory

    public init(
        decision: ReviewDecision,
        risk: RiskLevel,
        confidence: ReviewerConfidence,
        rationale: String,
        rationaleCategory: ReviewRationaleCategory
    ) {
        self.decision = decision
        self.risk = risk
        self.confidence = confidence
        self.rationale = rationale
        self.rationaleCategory = rationaleCategory
    }

    public var hasConflictingRationale: Bool {
        switch (decision, rationaleCategory) {
        case (.allow, .deny), (.deny, .allow):
            return true
        default:
            return false
        }
    }
}

/// Provider-independent reviewer. Implementations live outside RVPolicy / RVEngine;
/// bind happens in `ReviewBind`.
public protocol ActionReviewer: Sendable {
    var providerID: ReviewerProviderID { get }
    func review(_ request: ReviewRequest) async throws -> ActionReview
}
