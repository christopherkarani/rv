#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// rv's one exit-code table (North Star A5, v2 "exit codes mean the same
/// thing everywhere"). Every command exits with one of these, except the
/// codes in `ExitStatus.kept`, which a caller outside rv depends on.
/// `ExitCodeTableTests` holds the sources to it.
public enum ExitStatus: Int32, CaseIterable, Sendable {
    /// It worked, or the answer is "nothing to do".
    case ok = 0
    /// rv stopped it, or something went wrong; the reason is on stderr.
    case stopped = 1
    /// What you named is not there (a file, a code, a proposal), or rv
    /// refused it or could not reach what it needs; older commands still
    /// use 2 for those, and the reason is on stderr.
    case notFound = 2
    /// The command line is wrong: a missing or bad argument or flag
    /// (`EX_USAGE`, what ArgumentParser and the typo check exit with).
    case usage = 64

    /// A code outside the table, where it is used, and who depends on it.
    struct Kept: Sendable {
        var code: Int32
        var name: String
        var why: String
    }

    /// Codes rv keeps for a caller that reads them. Each is a decision for
    /// Chris before it can join the table.
    static let kept: [Kept] = [
        Kept(code: 3, name: "rvd did not answer", why: "rv policy status / --wait: a script can tell 'not confirmed' from 'failed' (exit 1)"),
        Kept(code: EX_DATAERR, name: "EX_DATAERR (65)", why: "config.json unreadable and setup data errors; setup and install scripts read sysexits"),
        Kept(code: EX_UNAVAILABLE, name: "EX_UNAVAILABLE (69)", why: "setup and service restart: rvd or launchd unavailable"),
        Kept(code: EX_SOFTWARE, name: "EX_SOFTWARE (70)", why: "setup and host mode internal errors"),
        Kept(code: EX_CANTCREAT, name: "EX_CANTCREAT (73)", why: "setup cannot write hooks, plists or config"),
        Kept(code: EX_IOERR, name: "EX_IOERR (74)", why: "a config change rv could not record in the audit log"),
        Kept(code: EX_NOPERM, name: "EX_NOPERM (77)", why: "owner confirmation refused (Touch ID, password, no terminal); OwnerConfirmation, F owns it"),
        Kept(code: EX_CONFIG, name: "EX_CONFIG (78)", why: "setup found a configuration it will not overwrite"),
        Kept(code: 125, name: "125-127", why: "rv run: refused, could not start, not found, as env(1) does"),
        Kept(code: 128, name: "128+N", why: "rv run and the rv mcp proxy: the child was killed by signal N, as shells report it"),
        Kept(code: 130, name: "130", why: "rv opencode cancelled by Ctrl-C (128+SIGINT)"),
    ]
}
