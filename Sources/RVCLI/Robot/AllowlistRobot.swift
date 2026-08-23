import Foundation
import RVPolicy

struct AllowlistRobotRow: Equatable, Sendable, Encodable {
    var reason: String
    var active: String
    var rule: String?
    var exactCommand: String?

    enum CodingKeys: String, CodingKey {
        case reason
        case active
        case rule
        case exactCommand = "exact_command"
    }
}

func allowlistRobotRows(from entries: [AllowlistEntry], now: Date) -> [AllowlistRobotRow] {
    entries.map { entry in
        let active = entry.isActive(at: now) ? "true" : "false"
        switch entry.selector {
        case .rule(let ruleID):
            return AllowlistRobotRow(
                reason: entry.reason,
                active: active,
                rule: ruleID.rawValue,
                exactCommand: nil
            )
        case .exactCommand(let command):
            return AllowlistRobotRow(
                reason: entry.reason,
                active: active,
                rule: nil,
                exactCommand: command.rawValue
            )
        }
    }
}
