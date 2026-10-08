import Foundation
import RVPolicy

struct AllowOnceRobotRow: Equatable, Sendable, Encodable {
    var kind: AllowOnceRecord.Kind
    var commandRedacted: String
    var cwd: String

    enum CodingKeys: String, CodingKey {
        case kind
        case commandRedacted = "command_redacted"
        case cwd
    }
}

/// Robot rows deliberately omit `codeHash`: the 24-bit code falls to
/// offline brute force in seconds, so the hash must never leave the store
/// file (B-F4). Nothing consumes it (verified: goldens only).
func allowOnceRobotRows(from rows: [AllowOnceListRow]) -> [AllowOnceRobotRow] {
    rows.map { row in
        AllowOnceRobotRow(
            kind: row.kind,
            commandRedacted: row.commandRedacted,
            cwd: row.cwd.rawValue
        )
    }
}
