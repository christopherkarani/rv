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
    /// the command's process group here. Answered by a probe of `peers`, so
    /// a platform whose peer check gains a backend passes without an edit.
    static func peerBindingVerifiable(_ peers: GatewayPeerCheck) -> Bool {
        SecretRunProcess.bindsProcessGroups(peers)
    }
}

/// When `rv run` hands the terminal to the command and takes it back. Pure:
/// it decides, `SecretRunProcess` acts. rv gives the terminal away only
/// while it holds the foreground, and takes it back only if it gave it away,
/// so a backgrounded rv never steals the terminal from the shell.
struct SecretRunJobControl: Equatable {
    private(set) var handed = false

    /// Before the command resumes: at launch, and each time rv itself is
    /// continued (`fg` gives rv the foreground first; `bg` does not).
    mutating func handsTerminal(rvInForeground: Bool) -> Bool {
        handed = rvInForeground
        return rvInForeground
    }

    /// When the command stops or exits.
    mutating func reclaimsTerminal() -> Bool {
        defer { handed = false }
        return true  // RED: reclaims unconditionally, as before the fix.
    }
}

/// Where `rv run` forwards the signals it receives: nowhere until the
/// command's group is known (the first one is kept), then to that group,
/// and nowhere again once `release` is called. `release` comes before the
/// leader is reaped: after that its group id may belong to someone else.
final class SecretRunSignalTarget: @unchecked Sendable {
    private let lock = NSLock()
    private let send: @Sendable (pid_t, Int32) -> Void
    private var group: pid_t?
    private var pending: Int32?
    private var released = false

    init(send: @escaping @Sendable (pid_t, Int32) -> Void = { group, number in _ = kill(-group, number) }) {
        self.send = send
    }

    /// From here on, signals go to `group`. Returns one that arrived before.
    func target(_ group: pid_t) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if released == false { self.group = group }
        return pending
    }

    func deliver(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if let group {
            send(group, number)
        } else if pending == nil, released == false {
            pending = number
        }
    }

    /// No signal is sent after this returns.
    func release() {
        // RED: not implemented yet.
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

    /// Spawns the command stopped, calls `bind` with its group, hands it the
    /// terminal when rv holds the foreground, resumes it, and returns its
    /// `waitpid` status. Any failure before the resume kills the child,
    /// which never ran.
    static func launch(
        executable: String, arguments: [String], environment: [String], manageTerminal: Bool,
        bind: (ProcessGroupFact) -> Result<Void, SecretRunRefusal>
    ) -> Result<Int32, SecretRunRefusal> {
        let terminal = manageTerminal ? SecretRunTerminal.controlling() : nil
        var job = SecretRunJobControl()
        let signals = SecretRunSignals()
        defer { signals.restore() }
        let pid: pid_t
        switch spawnSuspended(
            executable: executable, arguments: arguments, environment: environment,
            descriptors: [STDIN_FILENO: STDIN_FILENO, STDOUT_FILENO: STDOUT_FILENO, STDERR_FILENO: STDERR_FILENO])
        {
        case .failure(let refusal): return .failure(refusal)
        case .success(let spawned): pid = spawned
        }
        func abandon(_ refusal: SecretRunRefusal) -> Result<Int32, SecretRunRefusal> {
            if job.reclaimsTerminal() { terminal?.reclaim() }
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
        if let terminal, job.handsTerminal(rvInForeground: terminal.rvInForeground), terminal.hand(to: pid) == false {
            return abandon(.spawnFailed("could not give it the terminal"))
        }
        guard kill(pid, SIGCONT) == 0 else { return abandon(.spawnFailed("could not resume it")) }
        return .success(supervise(pid, terminal: terminal, job: &job, signals: signals))
    }

    /// `POSIX_SPAWN_SETPGROUP` makes the child its own group leader inside
    /// the spawn call and `POSIX_SPAWN_START_SUSPENDED` stops it before its
    /// image runs, so there is no moment where it executes unbound. Only
    /// `descriptors` (child fd: rv fd) are inherited; every other descriptor
    /// (the gateway listener among them) stays in rv.
    static func spawnSuspended(
        executable: String, arguments: [String], environment: [String], descriptors: [Int32: Int32]
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
        _ pid: pid_t, terminal: SecretRunTerminal?, job: inout SecretRunJobControl, signals: SecretRunSignals
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
                if job.reclaimsTerminal() { terminal?.reclaim() }
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
            if job.reclaimsTerminal() { terminal.reclaim() }
            _ = kill(getpid(), SIGSTOP)
            if job.handsTerminal(rvInForeground: terminal.rvInForeground) { _ = terminal.hand(to: pid) }
            _ = kill(-pid, SIGCONT)
        }
        if job.reclaimsTerminal() { terminal?.reclaim() }
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
        // RED: the old consume, which reaps an exit that raced the stop.
        var status: Int32 = 0
        guard waitpid(pid, &status, WUNTRACED | WNOHANG) == pid, SecretRunExit.isStopped(waitStatus: status) else {
            return nil
        }
        return (status >> 8) & 0xff
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

#if os(macOS)
/// One loopback connection rv holds both ends of, for the capability probe.
struct SecretRunLoopback {
    let client: Int32
    let server: Int32
    /// The connection as the gateway would name it from `server`.
    let peer: GatewayPeer

    func close() {
        _ = Darwin.close(client)
        _ = Darwin.close(server)
    }

    /// A listener on 127.0.0.1 and an ephemeral port.
    static func listen() -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && Darwin.listen(fd, 2) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard ready else {
            _ = Darwin.close(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    static func connect(_ listener: (fd: Int32, port: UInt16)) -> SecretRunLoopback? {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return nil }
        var address = loopback(port: listener.port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        let server = connected ? accept(listener.fd, nil, nil) : -1
        guard server >= 0, let peer = GatewayPeer.of(server) else {
            _ = Darwin.close(client)
            if server >= 0 { _ = Darwin.close(server) }
            return nil
        }
        return SecretRunLoopback(client: client, server: server, peer: peer)
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = GatewayPeer.loopback
        return address
    }
}

/// rv's controlling terminal. The command gets the foreground for its run
/// while rv holds it, so Ctrl-C and Ctrl-Z reach its group, and rv takes it
/// back (with the modes it had) when the command stops or exits.
struct SecretRunTerminal {
    let fd: Int32
    private let saved: termios

    /// Nil when `fd` is not rv's controlling terminal. rv may be in the
    /// background: it then hands nothing until the shell gives it the
    /// foreground with `fg`.
    static func controlling(_ fd: Int32 = STDIN_FILENO) -> SecretRunTerminal? {
        guard isatty(fd) == 1, tcgetpgrp(fd) > 0 else { return nil }
        var modes = termios()
        guard tcgetattr(fd, &modes) == 0 else { return nil }
        return SecretRunTerminal(fd: fd, saved: modes)
    }

    private init(fd: Int32, saved: termios) {
        self.fd = fd
        self.saved = saved
    }

    var rvInForeground: Bool { tcgetpgrp(fd) == getpgrp() }

    /// `SIGTTOU` must be ignored (as `SecretRunSignals` does): once the
    /// command holds the foreground, rv is a background process.
    func hand(to group: pid_t) -> Bool {
        tcsetpgrp(fd, group) == 0
    }

    /// Only after `hand`, per `SecretRunJobControl`.
    func reclaim() {
        _ = tcsetpgrp(fd, getpgrp())
        var modes = saved
        _ = tcsetattr(fd, TCSADRAIN, &modes)
    }
}

/// While `rv run` supervises: `SIGINT`, `SIGTERM` and `SIGHUP` sent to rv
/// go to the command's group (through `SecretRunSignalTarget`) instead of
/// ending rv, and `SIGTTOU` is ignored so rv can take the terminal back
/// from the background. A signal that lands before the group is targeted
/// is kept, and the launch abandoned.
final class SecretRunSignals: @unchecked Sendable {
    static let forwarded = [SIGINT, SIGTERM, SIGHUP]

    private let lock = NSLock()
    private let forwarding = SecretRunSignalTarget()
    private var sources: [any DispatchSourceSignal] = []
    private var previous: [(number: Int32, handler: sig_t?)] = []

    init() {
        let queue = DispatchQueue(label: "rv.run.signals")
        lock.lock()
        defer { lock.unlock() }
        for number in Self.forwarded + [SIGTTOU] {
            previous.append((number, signal(number, SIG_IGN)))
        }
        let forwarding = forwarding
        for number in Self.forwarded {
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { forwarding.deliver(number) }
            source.resume()
            sources.append(source)
        }
    }

    func target(_ group: pid_t) -> Int32? { forwarding.target(group) }

    /// Before the leader is reaped.
    func release() { forwarding.release() }

    /// Restores the dispositions rv had before.
    func restore() {
        forwarding.release()
        lock.lock()
        defer { lock.unlock() }
        for source in sources { source.cancel() }
        sources.removeAll()
        for entry in previous { _ = signal(entry.number, entry.handler) }
        previous.removeAll()
    }
}
#endif
