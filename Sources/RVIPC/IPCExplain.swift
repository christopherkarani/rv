import Foundation
import RVDomain

public struct ExplainParams: Sendable, Equatable, Codable {
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

public struct ExplainStage: Sendable, Equatable, Codable {
    public var name: ExplainStep.ID
    public var elapsedMs: Double

    public init(name: ExplainStep.ID, elapsedMs: Double) {
        self.name = name
        self.elapsedMs = elapsedMs
    }

    enum CodingKeys: String, CodingKey {
        case name
        case elapsedMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .name)
        guard let name = ExplainStep.ID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "unknown ExplainStage name \(raw)"
            )
        }
        self.name = name
        elapsedMs = try container.decode(Double.self, forKey: .elapsedMs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name.rawValue, forKey: .name)
        try container.encode(elapsedMs, forKey: .elapsedMs)
    }
}

public struct ExplainReply: Sendable, Equatable, Codable {
    public var result: EvaluationResult
    public var normalized: String
    public var ruleID: RuleID?
    public var packID: PackID?
    public var suggestion: String?
    public var stages: [ExplainStage]

    public init(
        result: EvaluationResult,
        normalized: String,
        suggestion: String? = nil,
        stages: [ExplainStage]
    ) {
        self.result = result
        self.normalized = normalized
        self.ruleID = result.outcome.explainRuleID
        self.packID = result.outcome.explainPackID
        self.suggestion = suggestion
        self.stages = stages
    }

    enum CodingKeys: String, CodingKey {
        case result
        case normalized
        case ruleID
        case packID
        case suggestion
        case stages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(EvaluationResult.self, forKey: .result)
        normalized = try container.decode(String.self, forKey: .normalized)
        suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion)
        stages = try container.decode([ExplainStage].self, forKey: .stages)
        ruleID = result.outcome.explainRuleID
        packID = result.outcome.explainPackID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result, forKey: .result)
        try container.encode(normalized, forKey: .normalized)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encodeIfPresent(packID, forKey: .packID)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
        try container.encode(stages, forKey: .stages)
    }
}
