import Foundation
import RVPolicy

struct AllowlistRobotRow: Equatable, Sendable, Encodable {
    var reason: String
    var active: Bool
    var selector: AllowlistSelector

    enum CodingKeys: String, CodingKey {
        case reason
        case active
        case rule
        case exactCommand = "exact_command"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        // Wire locks `active` to the strings "true"/"false", not JSON booleans.
        try container.encode(active ? "true" : "false", forKey: .active)
        switch selector {
        case .rule(let ruleID):
            try container.encode(ruleID.rawValue, forKey: .rule)
        case .exactCommand(let command):
            try container.encode(command.rawValue, forKey: .exactCommand)
        }
    }
}

func allowlistRobotRows(from entries: [AllowlistEntry], now: Date) -> [AllowlistRobotRow] {
    entries.map { entry in
        AllowlistRobotRow(
            reason: entry.reason,
            active: entry.isActive(at: now),
            selector: entry.selector
        )
    }
}
