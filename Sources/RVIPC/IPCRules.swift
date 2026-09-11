import Foundation
import RVDomain

public enum RulePolarity: String, Sendable, Equatable {
    case allow
    case block
}

extension RulePolarity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "allow":
            self = .allow
        case "block":
            self = .block
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Cannot initialize RulePolarity from invalid String value \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RulePreviewParams: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var polarity: RulePolarity

    public init(id: ApprovalID, polarity: RulePolarity) {
        self.id = id
        self.polarity = polarity
    }
}

public struct RulePreviewReply: Sendable, Equatable, Codable {
    public var sentence: String
    public var draft: String
    public var allowedToSave: Bool

    public init(sentence: String, draft: String, allowedToSave: Bool) {
        self.sentence = sentence
        self.draft = draft
        self.allowedToSave = allowedToSave
    }
}

public struct RuleSaveParams: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var polarity: RulePolarity
    public var draft: String

    public init(id: ApprovalID, polarity: RulePolarity, draft: String) {
        self.id = id
        self.polarity = polarity
        self.draft = draft
    }
}

public struct RuleSaveReply: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var waitResolved: Bool

    public init(ruleID: RuleID, waitResolved: Bool) {
        self.ruleID = ruleID
        self.waitResolved = waitResolved
    }
}
