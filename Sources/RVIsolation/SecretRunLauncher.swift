#if os(Linux)
import Foundation
import Glibc

/// How `rv run` starts a command stopped on Linux. glibc's `posix_spawn`
/// has no `POSIX_SPAWN_START_SUSPENDED`, so the child is a launcher,
/// `rv-isolation-exec --stopped` (Sources/rv-isolation-exec/main.c), which
/// closes every descriptor it must not pass on, stops itself with
/// `SIGSTOP`, and execs the command once continued. rv waits for that
/// stop, so when `spawnSuspended` returns the child has run none of the
/// command's image and holds none of rv's descriptors; pid, process group
/// and start time survive `exec`, so what rv then binds is the command.
package enum SecretRunLauncher {
    /// The launcher installed beside the running executable (rv-cli, or a
    /// test runner in the build directory). Found from the kernel's
    /// `/proc/self/exe`, never from `PATH` or `argv[0]`. Nil when it is
    /// not there or not an executable file. The MCP gateway's Landlock
    /// cage runs through the same helper.
    package static func path(besideExecutable executable: String? = posixRealpath("/proc/self/exe")) -> String? {
        guard let executable else { return nil }
        let path = URL(fileURLWithPath: executable).deletingLastPathComponent()
            .appendingPathComponent(IsolationBackends.isolationExecName).path
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 else { return nil }
        return path
    }

    /// The first descriptor the launcher closes: one past the highest the
    /// child is given. Never below 3, so stdio is never closed here.
    struct Floor: Equatable, Sendable {
        let rawValue: Int32

        /// Nil unless the descriptors above stdio are 3, 4, ... with no gap:
        /// the launcher closes from the floor up, so a number left out
        /// below it would pass on whatever rv has open there.
        init?(keeping descriptors: some Sequence<Int32>) {
            let kept = Set(descriptors)
            guard kept.allSatisfy({ $0 >= 0 }) else { return nil }
            var floor: Int32 = STDERR_FILENO + 1
            while kept.contains(floor) { floor += 1 }
            guard kept.allSatisfy({ $0 < floor }) else { return nil }
            rawValue = floor
        }
    }

    /// The launcher's argv: the floor, the pid that must be its parent
    /// before and after its stop (this rv), the executable, then the
    /// command's own argv.
    static func arguments(floor: Floor, parent: pid_t, executable: String, arguments: [String]) -> [String] {
        [IsolationBackends.isolationExecName, "--stopped", String(floor.rawValue), String(parent), "--", executable]
            + arguments
    }

    /// What `waitid` reported about the launcher before rv resumed it.
    enum State: Equatable, Sendable {
        /// Stopped by `SIGSTOP`: it reached its own stop, descriptors closed.
        case ready
        /// Stopped by something else. Not the state rv binds in.
        case stopped(by: Int32)
        /// Ended on its own (125: it refused its arguments, or could not
        /// close descriptors). Already reaped.
        case exited(Int32)
        /// Killed by a signal. Already reaped.
        case killed(by: Int32)
    }

    /// Nil for a report that is none of these (`CLD_CONTINUED`, `CLD_TRAPPED`).
    static func state(code: Int32, status: Int32) -> State? {
        switch code {
        case Int32(CLD_STOPPED): status == SIGSTOP ? .ready : .stopped(by: status)
        case Int32(CLD_EXITED): .exited(status)
        case Int32(CLD_KILLED), Int32(CLD_DUMPED): .killed(by: status)
        default: nil
        }
    }

    /// Why a launcher that did not reach its stop means no command.
    static func refusal(_ state: State?) -> SecretRunRefusal {
        switch state {
        case .ready: .spawnFailed("the launcher was not waited for")
        case .stopped(let signal): .spawnFailed("the launcher was stopped by signal \(signal) before it was ready")
        case .exited(let code): .spawnFailed("the launcher refused to start it (exit \(code))")
        case .killed(let signal): .spawnFailed("the launcher was killed by signal \(signal)")
        case nil: .spawnFailed("the launcher could not be observed")
        }
    }
}

extension siginfo_t {
    /// `si_pid` and `si_status` of a `SIGCHLD` report, which glibc defines
    /// as macros over a union that Swift does not import.
    var si_pid: pid_t { _sifields._sigchld.si_pid }
    var si_status: Int32 { _sifields._sigchld.si_status }
}

extension SecretRunProcess {
    /// How long the launcher has to reach its stop. It does nothing but
    /// close descriptors first; one that has not stopped by then is killed.
    static let launcherDeadline: TimeInterval = 10

    /// The Linux spawn primitive: the launcher as its own group leader
    /// (`POSIX_SPAWN_SETPGROUP`), with only `descriptors` (child fd: rv fd),
    /// returned once it has stopped itself. A launcher that exits, is
    /// killed, stops for any other reason or does not stop in time is not
    /// returned: it is dead and reaped, and the command never ran. A signal
    /// in `keepIgnored` is one rv's guard left ignored, as rv inherited it:
    /// it is not reset, so it stays ignored for the child.
    static func spawnSuspended(
        executable: String, arguments: [String], environment: [String], descriptors: [Int32: Int32],
        keepIgnored: Set<Int32> = [], launcher: String? = SecretRunLauncher.path(),
        deadline: TimeInterval = launcherDeadline
    ) -> Result<pid_t, SecretRunRefusal> {
        guard let launcher else {
            return .failure(.spawnFailed(
                "\(IsolationBackends.isolationExecName) is not installed beside rv, and rv cannot start a command "
                    + "stopped without it; reinstall rv"))
        }
        guard let floor = SecretRunLauncher.Floor(keeping: descriptors.keys) else {
            return .failure(.spawnFailed("spawn file actions"))
        }
        var attributes = posix_spawnattr_t()
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.spawnFailed("spawn attributes")) }
        defer { posix_spawnattr_destroy(&attributes) }
        // rv ignores some of these while it supervises; the command gets the defaults.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaulted = sigset_t()
        sigemptyset(&defaulted)
        for number in [SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGWINCH]
        where keepIgnored.contains(number) == false {
            sigaddset(&defaulted, number)
        }
        guard
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaulted) == 0
        else { return .failure(.spawnFailed("spawn attributes")) }
        var actions = posix_spawn_file_actions_t()
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.spawnFailed("spawn file actions")) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Every number below the floor is given or closed: the launcher
        // closes from the floor up, and nothing else of rv's may be left.
        // In number order, so a source below the floor must be a number
        // that is itself passed on (every caller's is, or is above it).
        for target in 0..<floor.rawValue {
            let source = descriptors[target]
            let passed = source.map { $0 != target || passesOn(descriptorFlags: fcntl($0, F_GETFD)) } ?? false
            let added = if let source, passed {
                posix_spawn_file_actions_adddup2(&actions, source, target)
            } else {
                posix_spawn_file_actions_addclose(&actions, target)
            }
            guard added == 0 else { return .failure(.spawnFailed("spawn file actions")) }
        }
        let argv = SpawnPointers(
            SecretRunLauncher.arguments(floor: floor, parent: getpid(), executable: executable, arguments: arguments))
        let envp = SpawnPointers(environment)
        defer {
            argv.release()
            envp.release()
        }
        var pid: pid_t = 0
        let spawned = argv.withPointers { argvPointer in
            envp.withPointers { envPointer in
                posix_spawn(&pid, launcher, &actions, &attributes, argvPointer, envPointer)
            }
        }
        guard let spawned, let status = spawned else { return .failure(.spawnFailed("spawn arguments")) }
        guard status == 0, pid > 1 else { return .failure(.spawnFailed(String(cString: strerror(status)))) }
        return awaitStop(pid, deadline: deadline)
    }

    /// Waits for the launcher's own stop and consumes its report, so the
    /// supervisor later sees only stops the command's signals cause.
    private static func awaitStop(_ pid: pid_t, deadline: TimeInterval) -> Result<pid_t, SecretRunRefusal> {
        let end = ContinuousClock.now + .seconds(deadline)
        var info = siginfo_t()
        while true {
            info = siginfo_t()
            // WCONTINUED: a stop someone else continued between two polls
            // is reported as that, not missed; it is not `ready`.
            let waited = waitid(P_PID, id_t(pid), &info, WSTOPPED | WCONTINUED | WEXITED | WNOHANG)
            if waited != 0 {
                if errno == EINTR { continue }
                // Not rv's child to wait for, so not rv's to signal either.
                return .failure(SecretRunLauncher.refusal(nil))
            }
            // With WNOHANG, no report yet leaves `si_pid` 0.
            if info.si_pid == pid { break }
            guard ContinuousClock.now < end else {
                // Alive, unreaped and rv's own: its group is still its own.
                discard(pid)
                return .failure(.spawnFailed("the launcher did not stop within \(Int(deadline)) seconds"))
            }
            usleep(500)
        }
        let state = SecretRunLauncher.state(code: info.si_code, status: info.si_status)
        switch state {
        case .ready:
            return .success(pid)
        case .stopped, nil:
            // Alive and unreaped: kill it before anything is bound to it.
            discard(pid)
            return .failure(SecretRunLauncher.refusal(state))
        case .exited, .killed:
            // `waitid` reaped it; its pid is no longer rv's to signal.
            return .failure(SecretRunLauncher.refusal(state))
        }
    }
}
#endif
