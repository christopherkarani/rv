import Darwin
import Foundation

/// `rv-macvm-agent exec-as USER -- PROGRAM ARGS...`: the agent's spawn
/// trampoline. It starts single-threaded in a fresh session, so it can
/// claim the terminal and drop privileges before `execv`. `-` keeps the
/// current user (host tests).
public enum ExecAs {
    public static let verb = "exec-as"
    public static let keepUser = "-"

    /// `arguments` excludes the executable and the verb.
    public static func run(_ arguments: [String]) -> Never {
        guard arguments.count >= 3, arguments[1] == "--", arguments[2].hasPrefix("/") else {
            fail("usage: rv-macvm-agent exec-as USER -- /PROGRAM [ARGS...]", status: 126)
        }
        if isatty(STDIN_FILENO) == 1 {
            _ = ioctl(STDIN_FILENO, TIOCSCTTY, 0)
        }
        let user = arguments[0]
        if user != keepUser {
            guard let entry = getpwnam(user) else { fail("no guest user \(user)", status: 126) }
            let uid = entry.pointee.pw_uid
            let gid = entry.pointee.pw_gid
            guard initgroups(user, Int32(bitPattern: gid)) == 0, setgid(gid) == 0, setuid(uid) == 0,
                getuid() == uid, geteuid() == uid, setuid(0) != 0
            else { fail("cannot become \(user): \(String(cString: strerror(errno)))", status: 126) }
        }
        let program = Array(arguments.dropFirst(2))
        _ = withCStrings(program) { argv in execv(program[0], argv) }
        fail("cannot run \(program[0]): \(String(cString: strerror(errno)))", status: errno == ENOENT ? 127 : 126)
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("rv-macvm-agent: \(message)\n".utf8))
        exit(status)
    }
}
