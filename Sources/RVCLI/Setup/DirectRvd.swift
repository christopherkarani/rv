#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Runs `rvd` without a supervisor, for Linux machines with no systemd
/// user manager (WSL without systemd, containers, OpenRC/runit, logins
/// without logind). The daemon gets its own session and /dev/null stdio
/// (rvd then logs to its own file), so it outlives setup and the terminal,
/// but nothing restarts it after logout, reboot or a crash.
protocol DirectRvdLaunching {
    /// Stops this user's rvd processes running `rvdPath` (or a replaced
    /// copy of it) and returns once they are gone, bounded.
    func stop(rvdPath: String)
    /// Starts `rvdPath` with `DirectRvd.arguments`, detached.
    func start(rvdPath: String) throws
}

enum DirectRvd {
    /// The systemd unit's arguments: resident for a year, like the unit.
    static let arguments = ["--socket", "--idle-exit-seconds=31536000"]

    /// The command a process supervisor should run.
    static func command(rvdPath: String) -> String {
        ([ShellWord.quote(rvdPath)] + arguments).joined(separator: " ")
    }

    /// What a direct start means for the user, and how to start rvd again.
    /// `rvPath` is the installed front door (`~/.local/bin/rv`).
    static func notice(command: String, rvPath: String, rvdPath: String, observing: Bool) -> String {
        let effect = observing ? "tool calls run unchecked" : "hooks ask about or deny tool calls"
        return """
            rv \(command): no systemd user manager is running (systemctl --user cannot reach one), so rv started rvd directly
            rvd will not survive logout or reboot, and nothing restarts it if it exits; while it is not running, \(effect)
            to start it again: \(ShellWord.quote(rvPath)) service start (to start it at login, add "\(ShellWord.quote(rvPath)) service start >/dev/null" to your shell profile, e.g. ~/.profile), or have your process supervisor run: \(DirectRvd.command(rvdPath: rvdPath))

            """
    }
}

/// Test default: never touches a process.
struct SilentDirectRvd: DirectRvdLaunching {
    func stop(rvdPath _: String) {}
    func start(rvdPath _: String) throws {}
}

enum DirectRvdError: Error, Equatable {
    case spawnFailed(Int32)
    case unsupported
}

#if os(Linux)
struct ProcessDirectRvd: DirectRvdLaunching {
    /// glibc and musl's `POSIX_SPAWN_SETSID` (not exported to Swift).
    static let spawnSetsid: Int16 = 0x80
    var procRoot = "/proc"
    var uid: uid_t = getuid()
    var terminateWait: TimeInterval = 3
    var killWait: TimeInterval = 1

    func stop(rvdPath: String) {
        let pids = Self.matchingPIDs(rvdPath: rvdPath, procRoot: procRoot, uid: uid)
        guard pids.isEmpty == false else { return }
        for pid in pids { kill(pid, SIGTERM) }
        if Self.waitGone(pids, seconds: terminateWait) { return }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        _ = Self.waitGone(pids, seconds: killWait)
    }

    func start(rvdPath: String) throws {
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A fresh signal mask and default dispositions: rv-cli's must not leak.
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGHUP, SIGINT, SIGPIPE, SIGTERM, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(
            &attributes,
            Self.spawnSetsid | Int16(POSIX_SPAWN_SETSIGMASK) | Int16(POSIX_SPAWN_SETSIGDEF)
        )
        let argv = [rvdPath] + DirectRvd.arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for pointer in cArgs { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, rvdPath, &actions, &attributes, &cArgs, environ)
        guard status == 0 else { throw DirectRvdError.spawnFailed(status) }
    }

    /// Processes of `uid` whose executable is `rvdPath`, or the deleted
    /// copy an upgrade replaced (`<path> (deleted)`).
    static func matchingPIDs(rvdPath: String, procRoot: String, uid: uid_t) -> [pid_t] {
        let canonical = URL(fileURLWithPath: rvdPath).resolvingSymlinksInPath().path
        let names = Set([rvdPath, canonical].flatMap { [$0, $0 + " (deleted)"] })
        let own = getpid()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: procRoot)) ?? []
        return entries.compactMap { entry -> pid_t? in
            guard let pid = pid_t(entry), pid > 0, pid != own else { return nil }
            var info = stat()
            guard stat(procRoot + "/" + entry, &info) == 0, info.st_uid == uid else { return nil }
            guard let exe = try? FileManager.default.destinationOfSymbolicLink(atPath: procRoot + "/" + entry + "/exe"),
                  names.contains(exe)
            else { return nil }
            return pid
        }
    }

    private static func waitGone(_ pids: [pid_t], seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            // A zombie child still answers kill(0); reap any that are ours.
            for pid in pids { _ = waitpid(pid, nil, WNOHANG) }
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return true }
            guard Date() < end else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
#endif
