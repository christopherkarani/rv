import Darwin
import Foundation
import RVMicroVMCore

/// The guest command's session. This agent's `exec-as` trampoline claims
/// the terminal (so the child gets the window size changes), then runs, in
/// a guest, `ssh` to the guest's `sshd`, which starts the `session` verb as
/// the guest user (see `MacVMSession`); in host tests (`user` nil) it runs
/// the `session` verb directly. The verb runs `sandbox-exec` with the
/// request's profile, then the command.
struct GuestChild {
    let pid: pid_t
    /// PTY master, or nil without a terminal.
    let master: Int32?
    let stdinPipe: Int32?
    let stdoutPipe: Int32?
    let stderrPipe: Int32?

    static let sandboxExec = "/usr/bin/sandbox-exec"

    static func argv(_ request: MacVMExecRequest, trampoline: String, user: String?) -> [String] {
        let session = user == nil ? [trampoline, MacVMSession.verb] : MacVMSession.sshArguments(terminal: request.terminal)
        return [trampoline, ExecAs.verb, ExecAs.keepUser, "--"] + session
    }

    /// The request rides in one variable: through `ssh`'s `SendEnv`, or
    /// straight to the verb.
    static func environment(_ request: MacVMExecRequest, user: String?) -> [String] {
        let session = "\(MacVMSession.variable)=\(MacVMSession.encode(request))"
        return user == nil ? [session] : [session, "PATH=/usr/bin:/bin", "HOME=/var/root"]
    }

    static func spawn(_ request: MacVMExecRequest, trampoline: String, user: String?) -> Result<GuestChild, AgentError> {
        var childEnds: [Int32] = []
        var parentEnds: (master: Int32?, stdin: Int32?, stdout: Int32?, stderr: Int32?) = (nil, nil, nil, nil)
        var stdio: [Int32] = []
        func closeAll() {
            (childEnds + [parentEnds.master, parentEnds.stdin, parentEnds.stdout, parentEnds.stderr].compactMap { $0 })
                .forEach { close($0) }
        }
        if request.terminal {
            guard let (master, slave) = openTerminal(rows: request.rows, columns: request.columns) else {
                return .failure(AgentError("cannot open a terminal: \(String(cString: strerror(errno)))"))
            }
            parentEnds.master = master
            childEnds = [slave]
            stdio = [slave, slave, slave]
        } else {
            var pipes: [[Int32]] = []
            for _ in 0..<3 {
                var ends: [Int32] = [0, 0]
                guard pipe(&ends) == 0 else {
                    closeAll()
                    pipes.joined().forEach { close($0) }
                    return .failure(AgentError("cannot create pipes: \(String(cString: strerror(errno)))"))
                }
                pipes.append(ends)
            }
            parentEnds = (nil, pipes[0][1], pipes[1][0], pipes[2][0])
            childEnds = [pipes[0][0], pipes[1][1], pipes[2][1]]
            stdio = childEnds
        }
        for fd in [parentEnds.master, parentEnds.stdin, parentEnds.stdout, parentEnds.stderr].compactMap({ $0 }) {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, source) in stdio.enumerated() {
            posix_spawn_file_actions_adddup2(&actions, source, Int32(target))
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session (the trampoline claims the terminal), only the
        // three stdio descriptors inherited, default signal dispositions.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        let arguments = argv(request, trampoline: trampoline, user: user)
        var pid: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(environment(request, user: user)) { envp in
                posix_spawn(&pid, trampoline, &actions, &attributes, argv, envp)
            }
        }
        childEnds.forEach { close($0) }
        childEnds = []  // already closed: `closeAll` must not close them again
        guard status == 0 else {
            closeAll()
            return .failure(AgentError("cannot start \(request.arguments[0]): \(String(cString: strerror(status)))"))
        }
        return .success(GuestChild(
            pid: pid, master: parentEnds.master, stdinPipe: parentEnds.stdin,
            stdoutPipe: parentEnds.stdout, stderrPipe: parentEnds.stderr
        ))
    }

    static func openTerminal(rows: UInt16, columns: UInt16) -> (Int32, Int32)? {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { return nil }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            close(master)
            return nil
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            return nil
        }
        resize(master, rows: rows, columns: columns)
        return (master, slave)
    }

    static func resize(_ master: Int32, rows: UInt16, columns: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Shell convention: exit code, or 128 + signal.
    static func shellStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

public struct AgentError: Error, Sendable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// NUL-terminated `char *[]` for the duration of `body`.
func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
