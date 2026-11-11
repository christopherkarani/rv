import Foundation
import RVIsolation

/// Whether this Linux account has a password that a login-password owner
/// check could ever accept.
///
/// `unix_chkpwd` answers a locked (`!`, `*`) or empty password exactly as it
/// answers a wrong one, so an SSH-key-only cloud user or root in a container
/// would be prompted, fail, and burn lockout strikes forever. `passwd -S`
/// reports the caller's own status without privileges on Debian, Ubuntu,
/// Arch and openSUSE (setuid `passwd`). Only a definite "locked" or "no
/// password" refuses up front; anything else (Fedora's `passwd` needs root,
/// a missing tool, a timeout, `no_new_privs`) is unknown and the normal
/// check runs. This only skips a prompt that could not succeed; it never
/// approves anything.
enum OwnerAccountPassword {
    enum Status: Sendable, Equatable {
        case usable
        /// Locked or empty: no typed password can match.
        case locked
        case unknown
    }

    /// Root-owned system paths only: a `passwd` earlier on PATH must not
    /// decide this.
    static let candidates = ["/usr/bin/passwd", "/bin/passwd"]

    /// `passwd -S <user>`: `<user> <status> …`, status `P`/`PS` (usable),
    /// `L`/`LK` (locked), `NP` (no password).
    static func status(passwdStatusOutput output: String, user: String) -> Status {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return .unknown }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, fields[0] == user else { return .unknown }
        switch fields[1] {
        case "L", "LK", "NP": return .locked
        case "P", "PS": return .usable
        default: return .unknown
        }
    }

    static func live(user: String?) -> Status {
        #if os(Linux)
        guard let user, user.isEmpty == false, user.hasPrefix("-") == false else { return .unknown }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .unknown
        }
        guard let outcome = BoundedProcess.run(
            tool, ["-S", user], environment: ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"],
            timeout: 3, maximumOutputBytes: 4096),
            outcome.status == 0
        else { return .unknown }
        return status(passwdStatusOutput: String(decoding: outcome.stdout, as: UTF8.self), user: user)
        #else
        _ = user
        return .unknown
        #endif
    }

    /// What the owner reads instead of a password prompt that cannot succeed.
    static func lockedRefusal(user: String) -> String {
        let fix = user == "root" ? "`passwd`" : "`sudo passwd \(user)`"
        return "this account (\(user)) has no password, so it cannot approve rv owner actions "
            + "(rv checks your login password); set one with \(fix) and try again"
    }

    /// The refusal for the current user when their account is definitely
    /// locked, else nil (go on and prompt).
    static func refusalIfLocked(
        user: String? = UserName.current, status: (String?) -> Status = live(user:)
    ) -> String? {
        guard let user, status(user) == .locked else { return nil }
        return lockedRefusal(user: user)
    }
}
