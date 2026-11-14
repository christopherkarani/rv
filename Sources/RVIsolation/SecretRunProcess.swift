#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Process primitives for `rv run`: a child that is its own process-group
/// leader from its first instruction and runs none before its placeholders
/// are bound, then its supervision until it exits. Where `isAvailable` is
/// false `rv run` refuses; giving a platform a no-window `launch` here (plus
/// a `GatewayPeerCheck` that binds process groups) is all `rv run` needs.
enum SecretRunProcess {
    #if os(macOS)
    static let isAvailable = true

    /// Spawns the command stopped, calls `bind` with its group, hands it the
    /// terminal when rv holds one, resumes it, and returns its `waitpid`
    /// status. Any failure before the resume kills the child, which never
    /// ran.
    static func launch(
        executable: String, arguments: [String], environment: [String], manageTerminal: Bool,
        bind: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        let terminal = manageTerminal ? SecretRunTerminal.foreground() : nil
        let signals = SecretRunSignals()
        defer { signals.restore() }
        let pid: pid_t
        switch spawnSuspended(executable: executable, arguments: arguments, environment: environment) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let spawned): pid = spawned
        }
        func abandon(_ refusal: SecretRunRefusal) -> Result<Int32, SecretRunRefusal> {
            terminal?.reclaim()
            discard(pid)
            return .failure(refusal)
        }
        guard let group = ProcessGroupRecovery.capture(pid: pid) else {
            return abandon(.bindFailed("its process group could not be read"))
        }
        if case .failure(let refusal) = bind(group) { return abandon(refusal) }
        if let pending = signals.target(pid) {
            // Interrupted before the command ran: it never will. The signal
            // number alone is the wait status of a process it killed.
            terminal?.reclaim()
            discard(pid)
            return .success(pending)
        }
        if let terminal, terminal.hand(to: pid) == false {
            return abandon(.spawnFailed("could not give it the terminal"))
        }
        guard kill(pid, SIGCONT) == 0 else { return abandon(.spawnFailed("could not resume it")) }
        return .success(supervise(pid, terminal: terminal))
    }

    /// `POSIX_SPAWN_SETPGROUP` makes the child its own group leader inside
    /// the spawn call and `POSIX_SPAWN_START_SUSPENDED` stops it before its
    /// image runs, so there is no moment where it executes unbound. Only
    /// stdio is inherited; every other descriptor (the gateway listener
    /// among them) stays in rv.
    static func spawnSuspended(
        executable: String, arguments: [String], environment: [String]
    ) -> Result<pid_t, SecretRunRefusal> {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.spawnFailed("spawn attributes")) }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        // rv ignores some of these while it supervises; the command gets the defaults.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaulted = sigset_t()
        sigemptyset(&defaulted)
        for number in [SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGWINCH, SIGINFO] {
            sigaddset(&defaulted, number)
        }
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaulted) == 0
        else { return .failure(.spawnFailed("spawn attributes")) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.spawnFailed("spawn file actions")) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addinherit_np(&actions, fd) == 0 else {
                return .failure(.spawnFailed("spawn file actions"))
            }
        }
        let argv = SpawnPointers(arguments)
        let envp = SpawnPointers(environment)
        defer {
            argv.release()
            envp.release()
        }
        var pid: pid_t = 0
        let spawned = argv.withPointers { argvPointer in
            envp.withPointers { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        guard let spawned, let status = spawned else { return .failure(.spawnFailed("spawn arguments")) }
        guard status == 0, pid > 1 else { return .failure(.spawnFailed(String(cString: strerror(status)))) }
        return .success(pid)
    }

    /// For a child that must never run: kills its group and reaps it.
    static func discard(_ pid: pid_t) {
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    /// Waits for the leader to exit, passing its stops through to rv's own
    /// job control when it holds the terminal. Before reaping, kills what is
    /// left of its group, as a contained runtime's teardown does: the
    /// unreaped leader keeps the group id from being reused, so the signal
    /// cannot reach an unrelated group. Returns the leader's `waitpid` status.
    static func supervise(_ pid: pid_t, terminal: SecretRunTerminal?) -> Int32 {
        let stops = terminal == nil ? 0 : WSTOPPED
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | stops | WNOWAIT) != 0 {
                if errno == EINTR { continue }
                break
            }
            guard info.si_code == CLD_STOPPED, let terminal else { break }
            var status: Int32 = 0
            _ = waitpid(pid, &status, WUNTRACED | WNOHANG)
            // Ctrl-Z stopped the command's group, which the shell does not
            // see; stop rv too so the shell regains the terminal, and on
            // `fg` hand it back and continue the group.
            terminal.reclaim()
            _ = kill(getpid(), SIGSTOP)
            _ = terminal.hand(to: pid)
            _ = kill(-pid, SIGCONT)
        }
        terminal?.reclaim()
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            // Unreapable: report it as killed rather than as success.
            guard errno == EINTR else { return SIGKILL }
        }
        return status
    }
    #else
    static let isAvailable = false

    static func launch(
        executable _: String, arguments _: [String], environment _: [String], manageTerminal _: Bool,
        bind _: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        .failure(.spawnUnavailable)
    }
    #endif
}

#if os(macOS)
/// The controlling terminal, when rv runs in its foreground group. The
/// command gets the foreground for its run, so Ctrl-C and Ctrl-Z reach its
/// group, and rv takes it back (with the modes it had) when the command
/// stops or exits.
struct SecretRunTerminal {
    let fd: Int32
    private let saved: termios

    /// Nil when `fd` is not a terminal, or rv is in the background.
    static func foreground(_ fd: Int32 = STDIN_FILENO) -> SecretRunTerminal? {
        guard isatty(fd) == 1, tcgetpgrp(fd) == getpgrp() else { return nil }
        var modes = termios()
        guard tcgetattr(fd, &modes) == 0 else { return nil }
        return SecretRunTerminal(fd: fd, saved: modes)
    }

    private init(fd: Int32, saved: termios) {
        self.fd = fd
        self.saved = saved
    }

    /// `SIGTTOU` must be ignored (as `SecretRunSignals` does) for a
    /// background rv to call this.
    func hand(to group: pid_t) -> Bool {
        tcsetpgrp(fd, group) == 0
    }

    func reclaim() {
        _ = tcsetpgrp(fd, getpgrp())
        var modes = saved
        _ = tcsetattr(fd, TCSADRAIN, &modes)
    }
}

/// While `rv run` supervises: `SIGINT`, `SIGTERM` and `SIGHUP` sent to rv
/// go to the command's group instead of ending rv, and `SIGTTOU` is ignored
/// so rv can take the terminal back from the background. A signal that
/// lands before the group is targeted is kept, and the launch abandoned.
final class SecretRunSignals: @unchecked Sendable {
    static let forwarded = [SIGINT, SIGTERM, SIGHUP]

    private let lock = NSLock()
    private var group: pid_t?
    private var pending: Int32?
    private var sources: [any DispatchSourceSignal] = []
    private var previous: [(number: Int32, handler: sig_t?)] = []

    init() {
        let queue = DispatchQueue(label: "rv.run.signals")
        lock.lock()
        defer { lock.unlock() }
        for number in Self.forwarded + [SIGTTOU] {
            previous.append((number, signal(number, SIG_IGN)))
        }
        for number in Self.forwarded {
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.deliver(number) }
            source.resume()
            sources.append(source)
        }
    }

    /// From here on, forwarded signals go to `group`. Returns a signal that
    /// arrived before, if one did.
    func target(_ group: pid_t) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        self.group = group
        return pending
    }

    private func deliver(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if let group {
            _ = kill(-group, number)
        } else if pending == nil {
            pending = number
        }
    }

    /// Restores the dispositions rv had before.
    func restore() {
        lock.lock()
        defer { lock.unlock() }
        for source in sources { source.cancel() }
        sources.removeAll()
        for entry in previous { _ = signal(entry.number, entry.handler) }
        previous.removeAll()
        group = nil
    }
}
#endif
