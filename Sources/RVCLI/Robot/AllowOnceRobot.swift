import Foundation
import RVPolicy

struct AllowOnceRobotRow: Equatable, Sendable, Encodable {
    var kind: String
    var codeHash: String
    var commandRedacted: String
    var cwd: String

    enum CodingKeys: String, CodingKey {
        case kind
        case codeHash = "code_hash"
        case commandRedacted = "command_redacted"
        case cwd
    }
}

func allowOnceRobotRows(from rows: [AllowOnceListRow]) -> [AllowOnceRobotRow] {
    rows.map { row in
        AllowOnceRobotRow(
            kind: row.kind.rawValue,
            codeHash: row.codeHash,
            commandRedacted: row.commandRedacted,
            cwd: row.cwd
        )
    }
}
