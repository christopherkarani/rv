import Foundation
import RVDomain

public enum ClassifyRisk: Sendable, Equatable {
    case safe
    case rated(Severity)
}

extension ClassifyRisk: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "safe" {
            self = .safe
        } else if let severity = Severity(rawValue: raw) {
            self = .rated(severity)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Cannot initialize ClassifyRisk from invalid String value \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .safe:
            try container.encode("safe")
        case .rated(let severity):
            try container.encode(severity.rawValue)
        }
    }
}

extension ClassifyRisk {
    /// Total derivation from `EvaluationOutcome`; unmatched deny is `.rated(.high)`.
    public static func derive(_ outcome: EvaluationOutcome) -> ClassifyRisk {
        switch outcome {
        case .quickRejected, .plain, .safeOnly:
            return .safe
        case .hit(let match, _):
            return .rated(match.severity)
        case .deny(_, .some(let match)):
            return .rated(match.severity)
        case .deny(_, .none):
            return .rated(.high)
        case .indeterminate:
            return .rated(.high)
        }
    }
}

public struct ClassifyParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: WorkingDirectory?

    public init(request: EvaluationRequest, cwd: WorkingDirectory? = nil) {
        self.request = request
        self.cwd = cwd
    }

    public init(from decoder: Decoder) throws {
        (request, cwd) = try RequestCwdCoding.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try RequestCwdCoding.encode(request: request, cwd: cwd, to: encoder)
    }
}

public struct ClassifyReason: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var explanation: String

    public init(ruleID: RuleID, explanation: String) {
        self.ruleID = ruleID
        self.explanation = explanation
    }
}

public struct ClassifyReply: Sendable, Equatable, Codable {
    public var decision: Decision
    public var risk: ClassifyRisk
    public var ruleID: RuleID?
    public var packID: PackID?
    public var reasons: [ClassifyReason]
    public var suggestions: [String]

    public init(result: EvaluationResult, suggestions: [String] = []) {
        self.decision = result.decision
        self.risk = ClassifyRisk.derive(result.outcome)
        self.ruleID = result.outcome.explainRuleID
        self.packID = result.outcome.explainPackID
        self.suggestions = suggestions
        switch result.outcome {
        case .hit(let match, _), .deny(_, .some(let match)):
            reasons = [
                ClassifyReason(
                    ruleID: match.ruleID,
                    explanation: match.explanation ?? match.reason
                )
            ]
        case .quickRejected, .plain, .safeOnly, .deny(_, .none), .indeterminate:
            reasons = []
        }
    }

    enum CodingKeys: String, CodingKey {
        case decision
        case risk
        case ruleID
        case packID
        case reasons
        case suggestions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(Decision.self, forKey: .decision)
        risk = try container.decode(ClassifyRisk.self, forKey: .risk)
        reasons = try container.decodeIfPresent([ClassifyReason].self, forKey: .reasons) ?? []
        suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        let siblingRuleID = try container.decodeIfPresent(RuleID.self, forKey: .ruleID)
        let siblingPackID = try container.decodeIfPresent(PackID.self, forKey: .packID)
        switch decision {
        case .allow:
            ruleID = siblingRuleID
            packID = siblingPackID
        case .deny(let deny):
            ruleID = deny.ruleID
            packID = deny.ruleID.pack
        case .indeterminate:
            ruleID = nil
            packID = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encode(risk, forKey: .risk)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encodeIfPresent(packID, forKey: .packID)
        try container.encode(reasons, forKey: .reasons)
        try container.encode(suggestions, forKey: .suggestions)
    }
}
