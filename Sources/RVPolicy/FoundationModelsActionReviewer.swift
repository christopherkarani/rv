import RVDomain

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models `ActionReviewer`. Constructs on every host.
/// On Linux / non-Apple / unavailable / timeout it throws a typed
/// `ActionReviewerError` and does not invent an allow.
///
/// Model output is advisory. `ShadowReviewRunner` must not bind it onto
/// the live decision.
public struct FoundationModelsActionReviewer: ActionReviewer {
    public static let defaultTimeout: Duration = .seconds(3)
    public static let defaultProviderID = ReviewerProviderID(rawValue: "apple.foundation-models")

    public var providerID: ReviewerProviderID { Self.defaultProviderID }
    public var timeout: Duration
    /// Production is `true`. Tests set `false` so payload capture cannot
    /// invoke the on-device model. False still builds the sanitized payload
    /// and then throws `.unsupported` — it cannot allow.
    package let usesSystemModel: Bool
    private let observePayload: (@Sendable (ReviewPromptPayload) -> Void)?

    public init(timeout: Duration = Self.defaultTimeout) {
        self.timeout = timeout
        self.usesSystemModel = true
        self.observePayload = nil
    }

    package init(
        timeout: Duration = Self.defaultTimeout,
        usesSystemModel: Bool,
        observePayload: (@Sendable (ReviewPromptPayload) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.usesSystemModel = usesSystemModel
        self.observePayload = observePayload
    }

    public func review(_ request: ReviewRequest) async throws -> ActionReview {
        let payload = ReviewPromptBuilder.payload(for: request)
        observePayload?(payload)
        #if canImport(FoundationModels)
        if usesSystemModel, #available(macOS 26, *) {
            return try await ReviewTimeout.run(timeout: timeout) {
                try await FoundationModelsReviewClient.review(payload: payload)
            }
        }
        #endif
        throw ActionReviewerError.unsupported
    }
}

/// Caps a model call so an unavailable or hung host cannot stall the live path.
enum ReviewTimeout: Sendable {
    static func run<T: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ActionReviewerError.timeout
            }
            do {
                guard let value = try await group.next() else {
                    throw ActionReviewerError.unsupported
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
enum FoundationModelsReviewDecision: Sendable {
    case allow
    case deny
    case abstain
}

@available(macOS 26, *)
@Generable
enum FoundationModelsReviewRisk: Sendable {
    case low
    case medium
    case high
    case critical
}

@available(macOS 26, *)
@Generable
enum FoundationModelsReviewConfidence: Sendable {
    case low
    case medium
    case high
}

@available(macOS 26, *)
@Generable
enum FoundationModelsReviewRationaleCategory: Sendable {
    case allow
    case deny
    case abstain
    case uncertain
}

@available(macOS 26, *)
@Generable
struct FoundationModelsReviewOutput: Sendable {
    var decision: FoundationModelsReviewDecision
    var risk: FoundationModelsReviewRisk
    var confidence: FoundationModelsReviewConfidence
    var rationale: String
    var rationaleCategory: FoundationModelsReviewRationaleCategory
}

@available(macOS 26, *)
enum FoundationModelsReviewClient: Sendable {
    static func review(payload: ReviewPromptPayload) async throws -> ActionReview {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        default:
            throw ActionReviewerError.unsupported
        }

        let session = LanguageModelSession()
        do {
            let response = try await session.respond(
                to: Prompt(payload.text),
                generating: FoundationModelsReviewOutput.self
            )
            return makeReview(response.content)
        } catch is CancellationError {
            throw ActionReviewerError.timeout
        } catch {
            throw ActionReviewerError.unsupported
        }
    }

    private static func makeReview(_ output: FoundationModelsReviewOutput) -> ActionReview {
        ActionReview(
            decision: reviewDecision(output.decision),
            risk: riskLevel(output.risk),
            confidence: reviewerConfidence(output.confidence),
            rationale: output.rationale,
            rationaleCategory: rationaleCategory(output.rationaleCategory)
        )
    }

    private static func reviewDecision(
        _ value: FoundationModelsReviewDecision
    ) -> ReviewDecision {
        switch value {
        case .allow:
            return .allow
        case .deny:
            return .deny
        case .abstain:
            return .abstain
        }
    }

    private static func riskLevel(_ value: FoundationModelsReviewRisk) -> RiskLevel {
        switch value {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .critical:
            return .critical
        }
    }

    private static func reviewerConfidence(
        _ value: FoundationModelsReviewConfidence
    ) -> ReviewerConfidence {
        switch value {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        }
    }

    private static func rationaleCategory(
        _ value: FoundationModelsReviewRationaleCategory
    ) -> ReviewRationaleCategory {
        switch value {
        case .allow:
            return .allow
        case .deny:
            return .deny
        case .abstain:
            return .abstain
        case .uncertain:
            return .uncertain
        }
    }
}
#endif
