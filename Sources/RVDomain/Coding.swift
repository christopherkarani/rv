extension RuleID: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = RuleID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid RuleID"
            )
        }
        self = parsed
    }
}

extension Decision: Codable {
    private enum CodingKeys: String, CodingKey {
        case decision
        case ruleID
        case reason
        case indeterminateReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allow:
            try container.encode("allow", forKey: .decision)
        case .deny(let deny):
            try container.encode("deny", forKey: .decision)
            try container.encode(deny.ruleID, forKey: .ruleID)
            try container.encode(deny.reason, forKey: .reason)
        case .indeterminate(let reason):
            try container.encode("indeterminate", forKey: .decision)
            try container.encode(reason, forKey: .indeterminateReason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .decision)
        switch kind {
        case "allow":
            self = .allow
        case "deny":
            let ruleID = try container.decode(RuleID.self, forKey: .ruleID)
            let reason = try container.decode(String.self, forKey: .reason)
            self = .deny(Deny(ruleID: ruleID, reason: reason))
        case "indeterminate":
            let reason = try container.decode(IndeterminateReason.self, forKey: .indeterminateReason)
            self = .indeterminate(reason)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .decision,
                in: container,
                debugDescription: "unknown Decision"
            )
        }
    }
}
