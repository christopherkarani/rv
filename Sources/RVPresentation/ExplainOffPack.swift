import RVDomain

/// A pack that is off with a rule that stops an explained command.
/// `rv explain` checked only the packs in force, so a command a bundled
/// pack would catch read as plain "allow" with no hint the pack exists.
public struct ExplainOffPack: Equatable, Sendable, Encodable {
    public var packID: PackID
    public var ruleID: RuleID
    /// The command that turns the pack on, ready to copy.
    public var turnOn: String

    public init(packID: PackID, ruleID: RuleID, turnOn: String) {
        self.packID = packID
        self.ruleID = ruleID
        self.turnOn = turnOn
    }

    /// `A rule in database.redis matches (database.redis:flushall)`. Not
    /// "would stop": the owner's allowlist and policy rules, which the
    /// probe does not apply, may still let the command run.
    public var display: String {
        "A rule in \(DisplayedText.field(packID.rawValue)) matches (\(DisplayedText.field(ruleID.rawValue)))"
    }

    enum CodingKeys: String, CodingKey {
        case packID = "pack_id"
        case ruleID = "rule_id"
        case turnOn = "turn_on"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packID.rawValue, forKey: .packID)
        try container.encode(ruleID.rawValue, forKey: .ruleID)
        try container.encode(turnOn, forKey: .turnOn)
    }
}
