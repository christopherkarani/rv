#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import Synchronization

/// A stdio server's process group as the runtime stops it: signalled as a
/// whole, and only while its leader is unreaped (so its group id cannot be
/// anyone else's yet).
protocol MCPSupervisedGroup: AnyObject, Sendable {
    /// Signals the whole group, unless the leader has been reaped.
    func signal(_ number: Int32)
    /// The leader has exited, reaped or not.
    var hasExited: Bool { get }
    /// Polls until the leader is reaped (and anything it held let go); false at `deadline`.
    func waitUntilFinished(until deadline: Date) -> Bool
}

extension SecretPlaceholderGroup: MCPSupervisedGroup {}

/// Why a server was not started; never quotes a value.
struct MCPStartFailure: Error, Sendable, Equatable {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}

/// A plain stdio server, started by `posix_spawn` as the leader of a new
/// process group with only its three standard descriptors. Its one
/// supervising thread is the only code that reaps it: it waits for the
/// leader to exit, kills what is left of the group, then reaps the leader,
/// as a placeholder server's supervisor does. So a stop reaches what the
/// server started in its group, and its exit is seen when it is reaped,
/// whoever still holds its stdout. What it started in a session or group of
/// its own (`setsid`, `docker run`'s container) is not reached.
final class MCPProcessGroup: MCPSupervisedGroup {
    private enum Phase: Equatable {
        case running
        case exited
        case reaped
    }

    let leader: pid_t
    private let phase = Mutex(Phase.running)

    private init(leader: pid_t) {
        self.leader = leader
    }

    func signal(_ number: Int32) {
        phase.withLock { phase in
            guard phase != .reaped else { return }
            _ = kill(-leader, number)
        }
    }

    var hasExited: Bool {
        phase.withLock { $0 != .running }
    }

    func waitUntilFinished(until deadline: Date) -> Bool {
        while phase.withLock({ $0 }) != .reaped {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    /// Starts `launch` with `descriptors` (child fd: rv fd) as its 0, 1 and
    /// 2 and nothing else of rv's. `exited` gets the leader's wait status
    /// once the group is killed and the leader reaped. On failure nothing
    /// ran, and the reason says why.
    static func spawn(
        _ launch: MCPUpstreamLaunch, descriptors: [Int32: Int32], exited: @escaping @Sendable (Int32) -> Void
    ) -> Result<MCPProcessGroup, MCPStartFailure> {
        let pid: pid_t
        switch spawnLeader(launch, descriptors: descriptors) {
        case .failure(let reason): return .failure(reason)
        case .success(let spawned): pid = spawned
        }
        let group = MCPProcessGroup(leader: pid)
        Thread.detachNewThread {
            exited(group.waitThenReap())
        }
        return .success(group)
    }

    private func waitThenReap() -> Int32 {
        var info = siginfo_t()
        // WNOWAIT: the exit is only observed here; the leader is reaped below, after the group kill.
        while waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT) != 0 {
            guard errno == EINTR else {
                // Not our unreaped child any more: its group id may be someone else's.
                phase.withLock { $0 = .reaped }
                return SIGKILL
            }
        }
        phase.withLock { phase in
            phase = .exited
            _ = kill(-leader, SIGKILL)
        }
        return phase.withLock { phase in
            var status: Int32 = 0
            while waitpid(leader, &status, 0) < 0 {
                // Unreapable: report it as killed rather than as success.
                guard errno == EINTR else {
                    status = SIGKILL
                    break
                }
            }
            phase = .reaped
            return status
        }
    }

    /// Every catchable signal: rv ignores SIGPIPE and may ignore others
    /// while it serves; the server gets the defaults, as from a shell.
    static var defaultedSignals: [Int32] {
        (1..<32).map { Int32($0) }.filter { $0 != SIGKILL && $0 != SIGSTOP }
    }

    private static func spawnLeader(_ launch: MCPUpstreamLaunch, descriptors: [Int32: Int32]) -> Result<pid_t, MCPStartFailure> {
        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        // Every descriptor not given below is closed in the child.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        #else
        var attributes = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        #endif
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(MCPStartFailure("spawn attributes")) }
        defer { posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaulted = sigset_t()
        sigemptyset(&defaulted)
        for number in defaultedSignals { sigaddset(&defaulted, number) }
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaulted) == 0
        else { return .failure(MCPStartFailure("spawn attributes")) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(MCPStartFailure("spawn file actions")) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, source) in descriptors.sorted(by: { $0.key < $1.key }) {
            // Sources are rv's own pipe ends, never 0 to 2 (`MCPPipe`).
            guard source != target, posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else {
                return .failure(MCPStartFailure("spawn file actions"))
            }
        }
        #if !canImport(Darwin)
        // No close-on-exec default here: everything else rv has open is closed.
        for fd in openDescriptors() where descriptors[fd] == nil && fd > STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { return .failure(MCPStartFailure("spawn file actions")) }
        }
        #endif
        if let directory = launch.workingDirectory, addChangeDirectory(&actions, directory) != 0 {
            return .failure(MCPStartFailure("spawn working directory"))
        }
        let argv = CStringVector([launch.executable] + launch.arguments)
        let envp = CStringVector(launch.environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            argv.release()
            envp.release()
        }
        var pid: pid_t = 0
        let status = argv.withPointers { argvPointer in
            envp.withPointers { envPointer in
                posix_spawn(&pid, launch.executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        guard status == 0, pid > 1 else { return .failure(MCPStartFailure(String(cString: strerror(status)))) }
        return .success(pid)
    }

    #if canImport(Darwin)
    private static func addChangeDirectory(_ actions: inout posix_spawn_file_actions_t?, _ path: String) -> Int32 {
        if #available(macOS 26, *) {
            posix_spawn_file_actions_addchdir(&actions, path)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, path)
        }
    }
    #else
    private static func addChangeDirectory(_ actions: inout posix_spawn_file_actions_t, _ path: String) -> Int32 {
        posix_spawn_file_actions_addchdir_np(&actions, path)
    }

    /// rv's open descriptors, from `/proc/self/fd`; the first 1024 numbers
    /// when that cannot be read. A number closed by the time of the spawn is
    /// harmless: glibc ignores a close that fails on an in-range descriptor.
    private static func openDescriptors() -> [Int32] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") else {
            return (3..<1024).map { Int32($0) }
        }
        return names.compactMap { Int32($0) }
    }
    #endif
}

/// One pipe, both ends close-on-exec and numbered above 2, so a spawn can
/// always `dup2` them onto a child's standard descriptors.
struct MCPPipe {
    let read: Int32
    let write: Int32

    static func make() -> MCPPipe? {
        var fds: [Int32] = [-1, -1]
        #if canImport(Darwin)
        guard pipe(&fds) == 0 else { return nil }
        #else
        guard pipe2(&fds, Int32(O_CLOEXEC)) == 0 else { return nil }
        #endif
        guard let read = lifted(fds[0]) else {
            close(fds[1])
            return nil
        }
        guard let write = lifted(fds[1]) else {
            close(read)
            return nil
        }
        return MCPPipe(read: read, write: write)
    }

    /// `fd`, close-on-exec, at a number above 2 (moved there if rv was
    /// started with a standard descriptor closed).
    private static func lifted(_ fd: Int32) -> Int32? {
        guard fd > STDERR_FILENO else {
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            close(fd)
            return moved < 0 ? nil : moved
        }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    func closeBoth() {
        close(read)
        close(write)
    }
}

/// C string vectors that live until `release()`.
private struct CStringVector {
    private let storage: [UnsafeMutablePointer<CChar>?]

    init(_ values: [String]) {
        storage = values.map { strdup($0) } + [nil]
    }

    func withPointers<T>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var values = storage
        return values.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    func release() {
        for pointer in storage { free(pointer) }
    }
}

/// When a launch's exit reaches the core: once its leader is reaped and
/// what it wrote has been read (its stdout reached EOF), or `grace` after
/// the reap when something it started still holds that stdout open. So a
/// last answer written just before it exited is handled before the exit,
/// and an exit is never missed. `fire` runs at most once.
final class MCPExitGate: Sendable {
    static let grace: TimeInterval = 1
    private let state = Mutex((reaped: false, drained: false, fired: false))
    private let fire: @Sendable () -> Void

    init(_ fire: @escaping @Sendable () -> Void) {
        self.fire = fire
    }

    /// Its stdout reached EOF.
    func drained() {
        let ready = state.withLock { state in
            state.drained = true
            return state.reaped
        }
        if ready { fireOnce() }
    }

    /// Its leader was reaped.
    func reaped() {
        let ready = state.withLock { state in
            state.reaped = true
            return state.drained
        }
        if ready {
            fireOnce()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.grace) { [self] in fireOnce() }
        }
    }

    private func fireOnce() {
        let first = state.withLock { state in
            defer { state.fired = true }
            return state.fired == false
        }
        if first { fire() }
    }
}
