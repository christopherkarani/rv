import RVDomain

/// A pack that is off but would stop an explained command if it were on.
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

    /// `Would stop if database.redis were on (database.redis:flushall)`
    public var display: String {
        "Would stop if \(DisplayedText.field(packID.rawValue)) were on (\(DisplayedText.field(ruleID.rawValue)))"
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
