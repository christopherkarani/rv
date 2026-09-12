import Foundation

/// One redacted denial. Path is already `$HOME` → `~`. No argv.
public struct DenialLedgerRecord: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var host: String
    public var tool: String
    public var ruleID: String
    public var category: String
    public var path: String

    public init(
        timestamp: Date,
        host: String,
        tool: String,
        ruleID: String,
        category: String,
        path: String
    ) {
        self.timestamp = timestamp
        self.host = host
        self.tool = tool
        self.ruleID = ruleID
        self.category = category
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case host
        case tool
        case ruleID = "rule_id"
        case category
        case path
    }
}
