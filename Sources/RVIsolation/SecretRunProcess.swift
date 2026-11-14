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
    #if os(macOS) || os(Linux)
    #if os(macOS)
    static let isAvailable = true
    #else
    /// The launcher (`SecretRunLauncher`) is what starts a command stopped here.
    static var isAvailable: Bool { SecretRunLauncher.path() != nil }
    #endif

    /// `launch` with rv's controlling terminal (when `manageTerminal`).
    /// `signals` is restored when it returns.
    static func launch(
        executable: String, arguments: [String], environment: [String], manageTerminal: Bool,
        signals: SecretRunSignals, notice: (String) -> Void,
        bind: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        let terminal = manageTerminal ? SecretRunTerminal.controlling() : nil
        defer { terminal?.close() }
        defer { signals.restore() }
        return launch(
            executable: executable, arguments: arguments, environment: environment, terminal: terminal,
            signals: signals, notice: notice, bind: bind)
    }

    /// Spawns the command stopped, calls `bind` with its group, hands it the
    /// terminal when rv holds the foreground alone, resumes it, and returns
    /// its `waitpid` status. Any failure before the resume kills the child,
    /// which never ran. `signals` must be open for the whole call.
    static func launch(
        executable: String, arguments: [String], environment: [String],
        terminal: (any SecretRunTerminalControl)?, signals: SecretRunSignals, notice: (String) -> Void,
        bind: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        var job = SecretRunJobControl()
        // Said before the spawn: no I/O between the spawn and the resume.
        if let terminal { tellHeldBack(foregroundState(terminal), job: &job, notice: notice) }
        let pid: pid_t
        switch spawnSuspended(
            executable: executable, arguments: arguments, environment: environment,
            descriptors: [STDIN_FILENO: STDIN_FILENO, STDOUT_FILENO: STDOUT_FILENO, STDERR_FILENO: STDERR_FILENO],
            keepIgnored: signals.inheritedIgnored)
        {
        case .failure(let refusal): return .failure(refusal)
        case .success(let spawned): pid = spawned
        }
        func abandon() {
            takeBack(terminal, &job)
            signals.release()
            discard(pid)
        }
        guard let group = ProcessGroupRecovery.capture(pid: pid) else {
            abandon()
            return .failure(.bindFailed("its process group could not be read"))
        }
        if case .failure(let refusal) = bind(group) {
            abandon()
            return .failure(refusal)
        }
        // Read again, but not told: if rv's group was shared only since, it
        // is said after the next stop.
        if let terminal, handOff(terminal, foregroundState(terminal), to: pid, job: &job, signals: signals) == false {
            abandon()
            return .failure(.spawnFailed("could not give it the terminal"))
        }
        // Armed last before the resume, so no failure above leaves a group
        // that a forwarded signal (and its SIGCONT) could reach.
        if let pending = signals.target(pid) {
            // Interrupted before the command ran: it never will. The signal
            // number alone is the wait status of a process it killed.
            abandon()
            return .success(pending)
        }
        guard kill(pid, SIGCONT) == 0 else {
            abandon()
            return .failure(.spawnFailed("could not resume it"))
        }
        return .success(supervise(pid, terminal: terminal, job: &job, signals: signals, notice: notice))
    }

    /// Whether rv holds the foreground, and whether its group holds anyone
    /// else: read only while it does, since otherwise nothing is handed.
    static func foregroundState(_ terminal: any SecretRunTerminalControl) -> (foreground: Bool, shares: Bool) {
        let foreground = terminal.rvInForeground
        return (foreground, foreground && terminal.sharesGroup)
    }

    /// Says once in a run why the terminal is held back, when `seen` has rv
    /// sharing its group.
    static func tellHeldBack(
        _ seen: (foreground: Bool, shares: Bool), job: inout SecretRunJobControl, notice: (String) -> Void
    ) {
        if job.tellsHeldBack(rvInForeground: seen.foreground, sharesGroup: seen.shares) {
            notice(SecretRunJobControl.heldBackNotice)
        }
    }

    /// Hands the terminal to `pid`'s group when `job` decides so for `seen`.
    /// False only when handing it failed.
    static func handOff(
        _ terminal: any SecretRunTerminalControl, _ seen: (foreground: Bool, shares: Bool), to pid: pid_t,
        job: inout SecretRunJobControl, signals: SecretRunSignals
    ) -> Bool {
        guard job.handsTerminal(
            rvInForeground: seen.foreground, sharesGroup: seen.shares,
            rvIgnoresInterrupt: signals.inheritedIgnored.contains(SIGINT), to: pid)
        else { return true }
        return terminal.hand(to: pid)
    }

    /// Takes the terminal back if rv handed it away and nobody else holds it.
    static func takeBack(_ terminal: (any SecretRunTerminalControl)?, _ job: inout SecretRunJobControl) {
        guard let terminal else { return }
        let foreground = terminal.foregroundGroup
        let alive = foreground.map(secretRunGroupExists) ?? false
        if job.reclaimsTerminal(foreground: foreground, foregroundAlive: alive) { terminal.reclaim() }
    }

    #if os(macOS)
    /// `POSIX_SPAWN_SETPGROUP` makes the child its own group leader inside
    /// the spawn call and `POSIX_SPAWN_START_SUSPENDED` stops it before its
    /// image runs, so there is no moment where it executes unbound. Only
    /// `descriptors` (child fd: rv fd) are inherited; every other descriptor
    /// (the gateway listener among them) stays in rv. A signal in
    /// `keepIgnored` stays ignored for the child, as rv inherited it. The
    /// child starts in `workingDirectory` when one is given, rv's otherwise.
    static func spawnSuspended(
        executable: String, arguments: [String], environment: [String], descriptors: [Int32: Int32],
        keepIgnored: Set<Int32> = [], workingDirectory: String? = nil
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
        for number in defaultedSignals(keepIgnored: keepIgnored) { sigaddset(&defaulted, number) }
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaulted) == 0
        else { return .failure(.spawnFailed("spawn attributes")) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.spawnFailed("spawn file actions")) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, source) in descriptors.sorted(by: { $0.key < $1.key }) {
            // Not passed on: POSIX_SPAWN_CLOEXEC_DEFAULT closes it in the child.
            if target == source, passesOn(descriptorFlags: fcntl(source, F_GETFD)) == false { continue }
            let added = target == source
                ? posix_spawn_file_actions_addinherit_np(&actions, target)
                : posix_spawn_file_actions_adddup2(&actions, source, target)
            guard added == 0 else { return .failure(.spawnFailed("spawn file actions")) }
        }
        if let workingDirectory, posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) != 0 {
            return .failure(.spawnFailed("spawn working directory"))
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
    #endif

    /// Whether a descriptor asked to be inherited as it is (same number in
    /// the child) is passed on, from its `fcntl(F_GETFD)` flags (-1 when it
    /// is closed). A descriptor rv was started with is never close-on-exec;
    /// every one rv opens is. So one that is closed, or close-on-exec, is
    /// not the caller's to pass on: rv was started without it (`<&-`) and
    /// its number is free, or now names something of rv's own. The child
    /// gets it closed.
    static func passesOn(descriptorFlags flags: Int32) -> Bool {
        flags != -1 && flags & FD_CLOEXEC == 0
    }

    /// What the command gets the default for: every signal rv may have
    /// inherited ignored or ignores itself while it supervises, except one
    /// rv inherited ignored, which the command keeps ignoring as a shell's
    /// child would.
    static func defaultedSignals(keepIgnored: Set<Int32>) -> [Int32] {
        (SecretRunSignals.forwarded + [SIGTTOU] + SecretRunSignals.untouched).filter { keepIgnored.contains($0) == false }
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
    /// rv's own job control when there is a terminal; without one a stop is
    /// only consumed, and the group stays stopped until something continues
    /// it. Before reaping, kills what is left of its group, as a contained
    /// runtime's teardown does: the unreaped leader keeps the group id from
    /// being reused, so the signal cannot reach an unrelated group.
    /// Forwarding stops before the reap, for the same reason. Returns the
    /// leader's `waitpid` status.
    static func supervise(
        _ pid: pid_t, terminal: (any SecretRunTerminalControl)?, job: inout SecretRunJobControl,
        signals: SecretRunSignals, notice: (String) -> Void
    ) -> Int32 {
        while true {
            var info = siginfo_t()
            // WNOWAIT: an exit is only observed here; the leader is reaped below, after the group kill.
            // WSTOPPED always: Darwin reports a stop even without it, and a stop is never an exit.
            if waitid(P_PID, id_t(pid), &info, WEXITED | WSTOPPED | WNOWAIT) != 0 {
                if errno == EINTR { continue }
                // Not our unreaped child any more: its pgid may already be
                // someone else's, so nothing is signalled.
                signals.release()
                takeBack(terminal, &job)
                return SIGKILL
            }
            guard info.si_code == CLD_STOPPED else { break }
            // Consume the stop. Without WEXITED this never reaps, even if the
            // leader exited since. The spawn suspension reads as a stop with
            // no signal; only a signal stop is passed on.
            guard consumeStop(pid) != nil, let terminal else { continue }
            // Ctrl-Z (or a background read) stopped the command's group,
            // which the shell does not see; stop rv too so the shell regains
            // the terminal. `fg` gives rv the foreground before continuing
            // it, and rv hands it on; `bg` does not, and the terminal stays
            // with the shell. Either way the group continues.
            takeBack(terminal, &job)
            terminal.stopSelf()
            let seen = foregroundState(terminal)
            tellHeldBack(seen, job: &job, notice: notice)
            _ = handOff(terminal, seen, to: pid, job: &job, signals: signals)
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
        signals _: SecretRunSignals, notice _: (String) -> Void,
        bind _: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        .failure(.spawnUnavailable)
    }

    static func bindsProcessGroups(_: GatewayPeerCheck) -> Bool { false }
    #endif
}
