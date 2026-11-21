#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

public enum WorkerSpawnError: Error, Sendable, Equatable {
    case pipe(Int32)
    case spawn(Int32)
    /// The executable changed on disk; the supervisor is exiting.
    case upgraded
}

/// Spawns workers with `posix_spawn`: stdin and stdout are pipes to the
/// supervisor, stderr is inherited (the judge log), nothing else is.
/// The executable and its arguments are fixed by the caller: never taken
/// from a client request or the environment.
public struct PosixWorkerSpawner: WorkerSpawning {
    public let executable: String
    public let arguments: @Sendable (WorkerSlot, WorkerCompute, ModelKey) -> [String]
    public let environment: [String: String]

    public init(
        executable: String,
        environment: [String: String],
        arguments: @escaping @Sendable (WorkerSlot, WorkerCompute, ModelKey) -> [String]
    ) {
        self.executable = executable
        self.environment = environment
        self.arguments = arguments
    }

    /// The worker arguments for `rv-judge --worker`.
    public static func judgeWorkerArguments(
        slot: WorkerSlot, compute: WorkerCompute, key: ModelKey
    ) -> [String] {
        ["--worker", "--compute", compute.rawValue, "--engine", key.engine, "--bundle", key.bundle]
    }

    public func spawn(
        slot: WorkerSlot, compute: WorkerCompute, key: ModelKey, output: @escaping @Sendable (WorkerOutput) -> Void
    ) throws -> any WorkerProcess {
        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw WorkerSpawnError.pipe(errno) }
        guard pipe(&fromChild) == 0 else {
            let code = errno
            close(toChild[0]); close(toChild[1])
            throw WorkerSpawnError.pipe(code)
        }
        // Every pipe end is close-on-exec in the supervisor, so a sibling
        // worker spawned later never inherits another worker's pipes. The
        // dup2 onto 0/1 in the child clears the flag on the copies it keeps.
        for fd in toChild + fromChild { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        #if canImport(Darwin)
        _ = fcntl(toChild[1], F_SETNOSIGPIPE, 1)
        #endif
        _ = fcntl(fromChild[0], F_SETFL, fcntl(fromChild[0], F_GETFL) | O_NONBLOCK)

        let pid: pid_t
        do {
            pid = try launch(stdin: toChild[0], stdout: fromChild[1], arguments: arguments(slot, compute, key))
        } catch {
            for fd in toChild + fromChild { close(fd) }
            throw error
        }
        close(toChild[0])
        close(fromChild[1])
        return PosixWorkerProcess(pid: pid, stdin: toChild[1], stdout: fromChild[0], output: output)
    }

    private func launch(stdin: Int32, stdout: Int32, arguments: [String]) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)

        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        // Only 0/1 (dup2) and 2 (inherited below) cross into the worker.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let result = (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            (envp + [nil]).withUnsafeBufferPointer { envpBuffer -> Int32 in
                // Never nil (each array holds at least the terminator);
                // Glibc's posix_spawn takes non-optional argv/envp.
                guard let argv = argvBuffer.baseAddress, let envp = envpBuffer.baseAddress else { return EINVAL }
                return posix_spawn(
                    &pid, executable, &actions, &attributes,
                    UnsafeMutablePointer(mutating: argv),
                    UnsafeMutablePointer(mutating: envp))
            }
        }
        guard result == 0 else { throw WorkerSpawnError.spawn(result) }
        return pid
    }
}

/// One spawned worker. Reads frames off its stdout on a private queue,
/// writes requests on another, and reaps it exactly once. `kill()` never
/// signals a reaped pid: exit is first observed without reaping (`waitid`
/// with `WNOWAIT`), so the pid cannot be reused before `reaped` is set.
final class PosixWorkerProcess: WorkerProcess, @unchecked Sendable {
    let pid: pid_t
    private let stdinFD: Int32
    private let reaped = Mutex(false)
    private let writer = DispatchQueue(label: "dev.rv.judge.worker.write")
    private let reader = DispatchQueue(label: "dev.rv.judge.worker.read")
    private let source: DispatchSourceRead
    private var decoder = FrameStreamDecoder()

    init(pid: pid_t, stdin: Int32, stdout: Int32, output: @escaping @Sendable (WorkerOutput) -> Void) {
        self.pid = pid
        self.stdinFD = stdin
        self.source = DispatchSource.makeReadSource(fileDescriptor: stdout, queue: reader)
        source.setEventHandler { [unowned self] in self.readAvailable(stdout, output: output) }
        source.setCancelHandler { [self] in
            close(stdout)
            // A worker that closed stdout is finished either way.
            self.kill()
            DispatchQueue.global(qos: .utility).async { self.reap(output: output) }
        }
        source.resume()
    }

    func send(_ frame: Data) {
        writer.async { [stdinFD] in
            Self.withoutSigpipe {
                frame.withUnsafeBytes { raw in
                    guard var base = raw.baseAddress else { return }
                    var remaining = raw.count
                    while remaining > 0 {
                        let n = write(stdinFD, base, remaining)
                        if n < 0 {
                            if errno == EINTR { continue }
                            return // EPIPE: the exit event follows.
                        }
                        remaining -= n
                        base += n
                    }
                }
            }
        }
    }

    /// Runs `body` so a write to a dead worker fails with EPIPE instead of
    /// killing the supervisor, without touching the process-wide SIGPIPE
    /// disposition. Darwin opts the descriptor out (`F_SETNOSIGPIPE` at
    /// spawn). Linux has no such flag: SIGPIPE is blocked on this thread for
    /// the write, and one it raised is consumed before unblocking.
    private static func withoutSigpipe(_ body: () -> Void) {
        #if canImport(Darwin)
        body()
        #else
        var pipeOnly = sigset_t()
        sigemptyset(&pipeOnly)
        sigaddset(&pipeOnly, SIGPIPE)
        var pendingBefore = sigset_t()
        sigpending(&pendingBefore)
        let wasPending = sigismember(&pendingBefore, SIGPIPE) == 1
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeOnly, &previous)
        body()
        if !wasPending {
            var pendingAfter = sigset_t()
            sigpending(&pendingAfter)
            if sigismember(&pendingAfter, SIGPIPE) == 1 {
                var zero = timespec(tv_sec: 0, tv_nsec: 0)
                while sigtimedwait(&pipeOnly, nil, &zero) < 0 && errno == EINTR {}
            }
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        #endif
    }

    func kill() {
        reaped.withLock { done in
            #if canImport(Darwin)
            if !done { _ = Darwin.kill(pid, SIGKILL) }
            #else
            if !done { _ = Glibc.kill(pid, SIGKILL) }
            #endif
        }
    }

    private func readAvailable(_ fd: Int32, output: @Sendable (WorkerOutput) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                for body in decoder.feed(Data(buffer[0..<n])) { output(.frame(body)) }
                if decoder.failed != nil {
                    source.cancel()
                    return
                }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            source.cancel() // EOF or a read error.
            return
        }
    }

    private func reap(output: @Sendable (WorkerOutput) -> Void) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        reaped.withLock { $0 = true }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        writer.async { [stdinFD] in close(stdinFD) }
        let signal = status & 0x7f
        output(.exited(description: Self.describe(status), signal: signal == 0 ? nil : signal))
    }

    static func describe(_ status: Int32) -> String {
        let signal = status & 0x7f
        if signal == 0 { return "status \((status >> 8) & 0xff)" }
        return "signal \(signal)"
    }
}
