public struct EvaluationBudget: Sendable, Equatable, Codable {
    public var maxPatternAttempts: Int

    public init(maxPatternAttempts: Int) {
        self.maxPatternAttempts = maxPatternAttempts
    }
}

/// Where a proposed command came from. Untrusted sources get stricter
/// judge thresholds (indirect-injection profile, laya-guard parity).
/// `unknown` is today's behavior for hosts that cannot supply provenance.
public enum ActionProvenance: String, Sendable, Equatable, Codable {
    case unknown
    case userTyped
    case agentPlan
    case toolOutput
    case web
    case email

    public var isUntrusted: Bool {
        switch self {
        case .toolOutput, .web, .email: return true
        case .unknown, .userTyped, .agentPlan: return false
        }
    }
}

public struct EvaluationRequest: Sendable, Equatable, Codable {
    public var command: ShellCommand
    public var enabledPacks: [PackID]
    public var budget: EvaluationBudget?
    public var provenance: ActionProvenance

    public init(
        command: ShellCommand,
        enabledPacks: [PackID],
        budget: EvaluationBudget? = nil,
        provenance: ActionProvenance = .unknown
    ) {
        self.command = command
        self.enabledPacks = enabledPacks
        self.budget = budget
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case command, enabledPacks, budget, provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(ShellCommand.self, forKey: .command)
        enabledPacks = try container.decode([PackID].self, forKey: .enabledPacks)
        budget = try container.decodeIfPresent(EvaluationBudget.self, forKey: .budget)
        // Tolerant: an unknown provenance raw value from a newer host
        // degrades to .unknown instead of failing the whole frame decode.
        let rawProvenance = try container.decodeIfPresent(String.self, forKey: .provenance)
        provenance = rawProvenance.flatMap(ActionProvenance.init(rawValue:)) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(enabledPacks, forKey: .enabledPacks)
        try container.encodeIfPresent(budget, forKey: .budget)
        // Omitted when unknown so pre-provenance wire frames stay byte-identical.
        if provenance != .unknown {
            try container.encode(provenance, forKey: .provenance)
        }
    }

    /// Day-one packs only (`core.filesystem`, `core.git`) and the default budget.
    public static func makeDayOne(command: ShellCommand) -> EvaluationRequest {
        EvaluationRequest(command: command, enabledPacks: dayOnePackIDs)
    }
}
