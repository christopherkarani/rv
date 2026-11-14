#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVHistory

/// A gate change refused because the audit log could not record it
/// (`ConfigChangeUnrecorded`): its own line and exit code, never "could not
/// write config" or "store unavailable".
enum ConfigChangeRefusal {
    /// sysexits(3) EX_IOERR, apart from owner-check refusals (EX_NOPERM) and
    /// other gate refusals (2).
    static let exitCode: Int32 = EX_IOERR

    static func message(command: String, _ error: ConfigChangeUnrecorded) -> String {
        "rv \(command): \(error)\n"
    }

    /// Writes the line and throws `ExitCode(exitCode)`.
    static func fail(command: String, _ error: ConfigChangeUnrecorded) throws -> Never {
        try CommandContext.fail(message(command: command, error), exitCode: exitCode)
    }
}
