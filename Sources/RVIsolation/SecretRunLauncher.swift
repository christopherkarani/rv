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
enum SecretRunLauncher {
    /// The launcher installed beside the running executable (rv-cli, or a
    /// test runner in the build directory). Found from the kernel's
    /// `/proc/self/exe`, never from `PATH` or `argv[0]`. Nil when it is
    /// not there or not an executable file.
    static func path(besideExecutable executable: String? = posixRealpath("/proc/self/exe")) -> String? {
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

        /// Nil when a kept descriptor is negative or too large to step past.
        init?(keeping descriptors: some Sequence<Int32>) {
            var highest: Int32 = STDERR_FILENO
            for descriptor in descriptors {
                guard descriptor >= 0, descriptor < Int32.max else { return nil }
                highest = max(highest, descriptor)
            }
            rawValue = highest + 1
        }
    }

    /// The launcher's argv: the executable, then the command's own argv.
    static func arguments(floor: Floor, executable: String, arguments: [String]) -> [String] {
        [IsolationBackends.isolationExecName, "--stopped", String(floor.rawValue), "--", executable] + arguments
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
    /// The Linux spawn primitive: the launcher as its own group leader
    /// (`POSIX_SPAWN_SETPGROUP`), with only `descriptors` (child fd: rv fd),
    /// returned once it has stopped itself. A launcher that exits, is
    /// killed, or stops for any other reason is not returned: it is dead
    /// and reaped, and the command never ran. A signal in `keepIgnored`
    /// stays ignored for the child, as rv inherited it.
    static func spawnSuspended(
        executable: String, arguments: [String], environment: [String], descriptors: [Int32: Int32],
        keepIgnored: Set<Int32> = []
    ) -> Result<pid_t, SecretRunRefusal> {
        guard let launcher = SecretRunLauncher.path() else {
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
        for (target, source) in descriptors.sorted(by: { $0.key < $1.key }) {
            // A descriptor rv itself has closed (stdin under `<&-`) stays
            // closed. Onto itself, dup2 clears close-on-exec.
            if target == source, fcntl(source, F_GETFD) == -1 { continue }
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else {
                return .failure(.spawnFailed("spawn file actions"))
            }
        }
        let argv = SpawnPointers(
            SecretRunLauncher.arguments(floor: floor, executable: executable, arguments: arguments))
        let envp = SpawnPointers(environment)
        defer {
            argv.release()
            envp.release()
        }
        // rv's guard holds the forwarded signals with a handler here
        // (`SecretRunSignalRelay`), and a handler does not survive `exec`:
        // the child would get the default back. Ignored across the spawn,
        // the ones rv inherited ignored stay ignored for the child.
        let held = keepIgnored.sorted().map { (number: $0, handler: signal($0, SIG_IGN)) }
        var pid: pid_t = 0
        let spawned = argv.withPointers { argvPointer in
            envp.withPointers { envPointer in
                posix_spawn(&pid, launcher, &actions, &attributes, argvPointer, envPointer)
            }
        }
        for entry in held.reversed() { _ = signal(entry.number, entry.handler) }
        guard let spawned, let status = spawned else { return .failure(.spawnFailed("spawn arguments")) }
        guard status == 0, pid > 1 else { return .failure(.spawnFailed(String(cString: strerror(status)))) }
        return awaitStop(pid)
    }

    /// Waits for the launcher's own stop and consumes its report, so the
    /// supervisor later sees only stops the command's signals cause.
    private static func awaitStop(_ pid: pid_t) -> Result<pid_t, SecretRunRefusal> {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WSTOPPED | WEXITED) != 0 {
            guard errno == EINTR else {
                // Not waitable: still rv's child, so its group is its own.
                discard(pid)
                return .failure(SecretRunLauncher.refusal(nil))
            }
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
