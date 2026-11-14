#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Whether this host can run `rv run`: a no-window spawn exists, and the
/// gateway's peer check really binds a placeholder to a spawned group. Both
/// are checked by doing them, never by platform name, so a platform that
/// gains either starts working without a change here.
package enum SecretRunCapability {
    /// Why `rv run` cannot launch here, or nil. Run before any secret is
    /// resolved: a refused launch prompts and unlocks nothing.
    static func check(_ peers: GatewayPeerCheck) -> SecretRunRefusal? {
        guard SecretRunProcess.isAvailable else { return .spawnUnavailable }
        return peerBindingVerifiable(peers) ? nil : .peerBindingUnavailable
    }

    /// The one place `rv run` asks whether the gateway can bind a request to
    /// the command's process group here. The host must be able to attribute
    /// a loopback connection at all (`GatewayPeerBinding.isVerifiable`), and
    /// `peers` must then bind a spawned group in a probe, so a peer check
    /// that answers for everything or for nothing is still refused.
    static func peerBindingVerifiable(_ peers: GatewayPeerCheck) -> Bool {
        GatewayPeerBinding.isVerifiable && SecretRunProcess.bindsProcessGroups(peers)
    }
}

/// Process primitives for `rv run`: a child that is its own process-group
/// leader from its first instruction and runs none before its placeholders
/// are bound, then its supervision until it exits. Where `isAvailable` is
/// false `rv run` refuses; giving a platform a no-window `launch` here is
/// all `rv run` needs from this file.
enum SecretRunProcess {
    #if os(macOS)
    static let isAvailable = true

    /// `launch` with rv's controlling terminal (when `manageTerminal`) and
    /// its own signal guard.
    static func launch(
        executable: String, arguments: [String], environment: [String], manageTerminal: Bool,
        bind: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        let terminal = manageTerminal ? SecretRunTerminal.controlling() : nil
        defer { terminal?.close() }
        let signals = SecretRunSignals()
        defer { signals.restore() }
        return launch(
            executable: executable, arguments: arguments, environment: environment, terminal: terminal,
            signals: signals, bind: bind)
    }

    /// Spawns the command stopped, calls `bind` with its group, hands it the
    /// terminal when rv holds the foreground alone, resumes it, and returns
    /// its `waitpid` status. Any failure before the resume kills the child,
    /// which never ran. `signals` must be installed for the whole call.
    static func launch(
        executable: String, arguments: [String], environment: [String],
        terminal: (any SecretRunTerminalControl)?, signals: SecretRunSignals,
        bind: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        var job = SecretRunJobControl()
        let pid: pid_t
        switch spawnSuspended(
            executable: executable, arguments: arguments, environment: environment,
            descriptors: [STDIN_FILENO: STDIN_FILENO, STDOUT_FILENO: STDOUT_FILENO, STDERR_FILENO: STDERR_FILENO],
            keepIgnored: signals.inheritedIgnored)
        {
        case .failure(let refusal): return .failure(refusal)
        case .success(let spawned): pid = spawned
        }
        func abandon(_ refusal: SecretRunRefusal) -> Result<Int32, SecretRunRefusal> {
            takeBack(terminal, &job)
            signals.release()
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
            signals.release()
            discard(pid)
            return .success(pending)
        }
        if let terminal,
            job.handsTerminal(rvInForeground: terminal.rvInForeground, sharesGroup: terminal.sharesGroup, to: pid),
            terminal.hand(to: pid) == false
        {
            return abandon(.spawnFailed("could not give it the terminal"))
        }
        guard kill(pid, SIGCONT) == 0 else { return abandon(.spawnFailed("could not resume it")) }
        return .success(supervise(pid, terminal: terminal, job: &job, signals: signals))
    }

    /// Takes the terminal back if rv handed it away and nobody else holds it.
    static func takeBack(_ terminal: (any SecretRunTerminalControl)?, _ job: inout SecretRunJobControl) {
        guard let terminal else { return }
        let foreground = terminal.foregroundGroup
        let alive = foreground.map(secretRunGroupExists) ?? false
        if job.reclaimsTerminal(foreground: foreground, foregroundAlive: alive) { terminal.reclaim() }
    }

    /// `POSIX_SPAWN_SETPGROUP` makes the child its own group leader inside
    /// the spawn call and `POSIX_SPAWN_START_SUSPENDED` stops it before its
    /// image runs, so there is no moment where it executes unbound. Only
    /// `descriptors` (child fd: rv fd) are inherited; every other descriptor
    /// (the gateway listener among them) stays in rv. A signal in
    /// `keepIgnored` stays ignored for the child, as rv inherited it.
    static func spawnSuspended(
        executable: String, arguments: [String], environment: [String], descriptors: [Int32: Int32],
        keepIgnored: Set<Int32> = []
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
        for number in [SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGWINCH, SIGINFO]
        where keepIgnored.contains(number) == false {
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
        for (target, source) in descriptors.sorted(by: { $0.key < $1.key }) {
            let added = target == source
                ? posix_spawn_file_actions_addinherit_np(&actions, target)
                : posix_spawn_file_actions_adddup2(&actions, source, target)
            guard added == 0 else { return .failure(.spawnFailed("spawn file actions")) }
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

    /// For a child that must never run: kills its group and reaps it. The
    /// child is unreaped until then, so its pgid cannot have been reused.
    static func discard(_ pid: pid_t) {
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    /// Waits for the leader to exit, passing its signal stops through to
    /// rv's own job control when there is a terminal. Before reaping, kills
    /// what is left of its group, as a contained runtime's teardown does:
    /// the unreaped leader keeps the group id from being reused, so the
    /// signal cannot reach an unrelated group. Forwarding stops before the
    /// reap, for the same reason. Returns the leader's `waitpid` status.
    static func supervise(
        _ pid: pid_t, terminal: (any SecretRunTerminalControl)?, job: inout SecretRunJobControl,
        signals: SecretRunSignals
    ) -> Int32 {
        let stops = terminal == nil ? 0 : WSTOPPED
        while true {
            var info = siginfo_t()
            // WNOWAIT: an exit is only observed here; the leader is reaped below, after the group kill.
            if waitid(P_PID, id_t(pid), &info, WEXITED | stops | WNOWAIT) != 0 {
                if errno == EINTR { continue }
                // Not our unreaped child any more: its pgid may already be
                // someone else's, so nothing is signalled.
                signals.release()
                takeBack(terminal, &job)
                return SIGKILL
            }
            guard info.si_code == CLD_STOPPED, let terminal else { break }
            // Consume the stop. Without WEXITED this never reaps, even if the
            // leader exited since. The spawn suspension reads as a stop with
            // no signal; only a signal stop is passed on.
            guard consumeStop(pid) != nil else { continue }
            // Ctrl-Z (or a background read) stopped the command's group,
            // which the shell does not see; stop rv too so the shell regains
            // the terminal. `fg` gives rv the foreground before continuing
            // it, and rv hands it on; `bg` does not, and the terminal stays
            // with the shell. Either way the group continues.
            takeBack(terminal, &job)
            terminal.stopSelf()
            if job.handsTerminal(rvInForeground: terminal.rvInForeground, sharesGroup: terminal.sharesGroup, to: pid) {
                _ = terminal.hand(to: pid)
            }
            _ = kill(-pid, SIGCONT)
        }
        takeBack(terminal, &job)
        _ = kill(-pid, SIGKILL)
        signals.release()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            // Unreapable: report it as killed rather than as success.
            guard errno == EINTR else { return SIGKILL }
        }
        return status
    }

    /// Consumes the leader's pending stop report and returns the signal that
    /// stopped it, or nil (the spawn suspension reads as a stop with no
    /// signal). Never reaps, even if the leader has exited since its stop
    /// was observed: the zombie keeps its group id from being reused.
    static func consumeStop(_ pid: pid_t) -> Int32? {
        var stop = siginfo_t()
        guard waitid(P_PID, id_t(pid), &stop, WSTOPPED | WNOHANG) == 0, stop.si_pid == pid,
            stop.si_code == CLD_STOPPED, stop.si_status != 0
        else { return nil }
        return stop.si_status
    }

    /// The kernel peer check binds here when a suspended probe child holding
    /// one end of a loopback connection reads as a member of its own group,
    /// and a connection it does not hold does not. The probe never runs:
    /// it is killed while still suspended.
    static func bindsProcessGroups(_ peers: GatewayPeerCheck) -> Bool {
        guard let listener = SecretRunLoopback.listen() else { return false }
        defer { close(listener.fd) }
        guard let held = SecretRunLoopback.connect(listener), let other = SecretRunLoopback.connect(listener) else {
            return false
        }
        defer { held.close(); other.close() }
        guard case .success(let pid) = spawnSuspended(
            executable: "/usr/bin/true", arguments: ["true"], environment: [], descriptors: [3: held.client])
        else { return false }
        defer { discard(pid) }
        guard let group = ProcessGroupRecovery.capture(pid: pid) else { return false }
        return peers.verify(held.peer, group) == .member && peers.verify(other.peer, group) != .member
    }
    #else
    static let isAvailable = false

    static func launch(
        executable _: String, arguments _: [String], environment _: [String], manageTerminal _: Bool,
        bind _: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        .failure(.spawnUnavailable)
    }

    static func bindsProcessGroups(_: GatewayPeerCheck) -> Bool { false }
    #endif
}
