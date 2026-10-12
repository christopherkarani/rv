#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization

/// One stdio MCP server subprocess: the `Process`-pipe seam behind
/// `MCPStdioChannel`'s `send` closure (X1-N).
///
/// Ports Executor `runMcpStdioServer` (`apps/local/src/mcp.ts:332`): real
/// process pipes, lifetime on `SIGINT` / `SIGTERM` / stdin end-close, and
/// the always-close `finally` shape (:357-360). Oracle behaviors pinned by
/// `packages/hosts/mcp/src/stdio-integration.test.ts` (stdio serving),
/// `e2e/local/stdio-mcp.test.ts` (daemon environment withheld from the
/// child), and `e2e/local/cli-mcp-daemon-attach-stress.test.ts` (concurrent
/// bridges). Every ported behavior cites its oracle in the member docs.
///
/// Framing is newline-delimited JSON: `send` writes one frame plus `\n` to
/// the child's stdin and reads one `\n`-terminated reply line from its
/// stdout, capped at `MCPMessageEnvelope.maximumBytes` each way. An
/// exchange lock serializes the write-plus-read as one unit so concurrent
/// callers can never split reply bytes across readers; the lock wait is
/// cancellation-aware and the waiter queue is bounded, and every exchange
/// races a deadline so one hung child wedges neither the handle nor its
/// callers.
///
/// `SIGPIPE` is ignored process-wide (permanently, like all `SIGPIPE`
/// discipline) so a dead child's closed pipes surface as errors, never as
/// a killed host.
public actor MCPStdioProcess {
    /// Pipe read chunk size. Small enough to exercise multi-chunk framing.
    private static let chunkSize = 4_096
    /// Grace for a natural exit after stdin EOF before `SIGTERM`.
    private static let terminateGraceMs = 200
    /// Grace after `SIGTERM` before `SIGKILL`.
    private static let killGraceMs = 500
    /// Poll step for exit waits.
    private static let pollStepNanoseconds: UInt64 = 5_000_000
    /// Default per-exchange budget (write-plus-read) in seconds. Covers
    /// slow tool backends behind the child; cancellation stays the fast
    /// path for abandonment.
    public static let defaultExchangeTimeoutSeconds = 30.0
    /// Most callers parked on the exchange lock. Far above legitimate
    /// per-handle bursts; only runaway queueing behind a wedged child
    /// trips it.
    static let maximumExchangeWaiters = 64
    /// Budget to resync framing (drain to the next newline) after a
    /// malformed reply. A responsive child resyncs in milliseconds; the
    /// bound only bites a trickling attacker.
    private static let drainGraceSeconds = 5.0
    /// Largest honored budget in seconds (sleep-overflow clamp, mirroring
    /// the op runner's cap).
    private static let maximumTimeoutSeconds = 1_000_000.0

    /// Live child pipes. One optional: nil means never spawned or closed.
    private struct LivePipes {
        /// The child process.
        var process: Process
        /// Write end of the child's stdin.
        var stdinWrite: FileHandle
        /// Read end of the child's stdout.
        var stdoutRead: FileHandle
    }

    private var live: LivePipes?
    private var didClose = false
    private var status: Int32?
    private var pending = Data()
    private var exchangeInFlight = false
    private var exchangeWaiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var exchangeWaiterNextID: UInt64 = 0

    /// Creates an unspawned process handle.
    public init() {}

    /// True while a child is spawned and running.
    public var isRunning: Bool {
        live?.process.isRunning ?? false
    }

    /// Spawns the child. Single-shot: a second spawn, or a spawn after
    /// close, throws `alreadySpawned`, mirroring the channel lifecycle
    /// where `closed` is terminal.
    ///
    /// - Throws: `MCPStdioProcessError.alreadySpawned` when single-shot is
    ///   violated, or `spawnFailed` when the executable is unusable.
    public func spawn(_ spec: MCPStdioProcessSpawn) throws(MCPStdioProcessError) {
        guard live == nil && didClose == false else {
            throw MCPStdioProcessError.alreadySpawned
        }
        guard Self.isAbsoluteExecutablePath(spec.executablePath) else {
            throw MCPStdioProcessError.spawnFailed
        }
        _ = signal(SIGPIPE, SIG_IGN)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: spec.executablePath)
        child.arguments = spec.arguments
        child.environment = spec.environment
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            throw MCPStdioProcessError.spawnFailed
        }
        live = LivePipes(
            process: child,
            stdinWrite: stdinPipe.fileHandleForWriting,
            stdoutRead: stdoutPipe.fileHandleForReading
        )
    }

    /// Exchanges one frame with the child: writes the frame plus `\n`,
    /// reads one reply line. Backs `MCPStdioChannel`'s `send` seam.
    ///
    /// The write-plus-read races `timeoutSeconds` (default
    /// `defaultExchangeTimeoutSeconds`): on timeout the transport fails
    /// closed and the exchange fails `.requestTimeout`, so one hung child
    /// wedges neither the handle nor its callers. A non-positive or
    /// non-finite budget times out immediately, before queueing.
    ///
    /// A malformed reply resyncs framing (drains to the next newline)
    /// before the lock releases, so the next exchange never frames this
    /// reply's tail as its own; when the drain itself fails, the transport
    /// fails closed instead.
    ///
    /// - Throws: `MCPTransportError.transportClosed` when unspawned,
    ///   closed, exited, or EOF-terminated mid-exchange,
    ///   `malformedEnvelope` when a frame or reply exceeds the cap or a
    ///   reply tears at EOF, `requestTimeout` when the budget expires,
    ///   `exchangeOverloaded` when the waiter queue is full, or
    ///   `CancellationError` when the caller cancels.
    public func send(
        _ frame: Data, timeoutSeconds: Double = MCPStdioProcess.defaultExchangeTimeoutSeconds
    ) async throws -> Data {
        if Task.isCancelled { throw CancellationError() }
        guard let live else { throw MCPTransportError.transportClosed }
        guard live.process.isRunning else { throw MCPTransportError.transportClosed }
        guard frame.count <= MCPMessageEnvelope.maximumBytes else { throw MCPTransportError.malformedEnvelope }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw MCPTransportError.requestTimeout }
        try await lockExchange()
        defer { unlockExchange() }
        guard let fresh = self.live, fresh.process.isRunning else { throw MCPTransportError.transportClosed }
        var request = frame
        request.append(0x0A)
        // Captured before the first suspension: `fileDescriptor` throws an
        // uncatchable NSException once `close` lands, while `read(2)` on the
        // raw fd fails cleanly with EBADF.
        let fd = fresh.stdoutRead.fileDescriptor
        do {
            return try await exchangeWithDeadline(
                stdin: fresh.stdinWrite, fd: fd, request: request,
                seconds: min(timeoutSeconds, Self.maximumTimeoutSeconds)
            )
        } catch let error as MCPTransportError where error == .malformedEnvelope {
            await resyncAfterMalformed(fd: fd)
            throw error
        }
    }

    /// Takes the exchange lock, queueing behind an in-flight exchange.
    /// Actor isolation alone cannot pair requests with replies: `send`
    /// suspends mid-exchange, so without this lock concurrent sends would
    /// split reply bytes across readers and strand them. The wait is
    /// cancellation-aware (a cancelled waiter withdraws instead of
    /// parking) and the queue is bounded at `maximumExchangeWaiters`.
    private func lockExchange() async throws -> Void {
        if exchangeInFlight == false {
            exchangeInFlight = true
            return
        }
        guard exchangeWaiters.count < Self.maximumExchangeWaiters else {
            throw MCPTransportError.exchangeOverloaded
        }
        let id = exchangeWaiterNextID
        exchangeWaiterNextID += 1
        try await withTaskCancellationHandler {
            // A cancel that landed before queueing (or an already-cancelled
            // task, whose handler ran first) must never park: fail instead.
            if Task.isCancelled { throw CancellationError() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exchangeWaiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandonWaiter(id) }
        }
    }

    /// Withdraws one cancelled waiter, resuming it with
    /// `CancellationError`. A grant that won the race already removed the
    /// waiter: a no-op then.
    private func abandonWaiter(_ id: UInt64) {
        if let index = exchangeWaiters.firstIndex(where: { $0.id == id }) {
            exchangeWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    /// Releases the exchange lock to the next waiter, if any.
    private func unlockExchange() {
        if exchangeWaiters.isEmpty {
            exchangeInFlight = false
            return
        }
        exchangeWaiters.removeFirst().continuation.resume()
    }

    /// Writes one frame and reads one reply line within `seconds`. The
    /// deadline races the whole write-plus-read as one unit. On timeout —
    /// or when the caller cancels mid-exchange — the transport fails
    /// closed: `close()` kills the child (so EPIPE unblocks a parked
    /// write) and retires the read fd (so EBADF unblocks a parked read),
    /// and the exchange fails `.requestTimeout` (`CancellationError` when
    /// the caller cancelled). A reply that completed before the deadline
    /// still returns, even under a late cancel: completed work wins.
    private func exchangeWithDeadline(
        stdin: FileHandle, fd: Int32, request: Data, seconds: Double
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do {
                    try stdin.write(contentsOf: request)
                } catch {
                    throw MCPTransportError.transportClosed
                }
                return try await self.readReplyLine(fd: fd)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPTransportError.requestTimeout
            }
            let first = await group.nextResult()
            switch first {
            case .success(let reply):
                group.cancelAll()
                while await group.nextResult() != nil {}
                return reply
            case .failure(let error as MCPTransportError) where error == .requestTimeout:
                await self.failClosed()
                group.cancelAll()
                while await group.nextResult() != nil {}
                throw error
            case .failure(let error):
                if Task.isCancelled {
                    await self.failClosed()
                    group.cancelAll()
                    while await group.nextResult() != nil {}
                    throw CancellationError()
                }
                group.cancelAll()
                while await group.nextResult() != nil {}
                throw error
            case .none:
                // Unreachable: two children always yield a result. Fail closed.
                group.cancelAll()
                while await group.nextResult() != nil {}
                if Task.isCancelled { throw CancellationError() }
                throw MCPTransportError.transportClosed
            }
        }
    }

    /// Resyncs framing after a malformed reply: discards bytes through the
    /// next newline (bounded by `drainGraceSeconds`), leaving post-newline
    /// bytes in `pending` for the next exchange. EOF resyncs to empty (the
    /// next read then fails closed at EOF, correctly). When the drain
    /// itself fails — deadline, fd error, or cancellation — the transport
    /// fails closed instead, which also unparks a still-draining reader so
    /// the race below always terminates. A torn frame never outlives the
    /// exchange.
    private func resyncAfterMalformed(fd: Int32) async {
        await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await self.drainToNewline(fd: fd) }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.drainGraceSeconds * 1_000_000_000)
                )
                return false
            }
            let first = await group.nextResult()
            let drained: Bool
            if case .success(true) = first {
                drained = true
            } else {
                drained = false
            }
            if drained == false {
                await self.failClosed()
            }
            group.cancelAll()
            while await group.nextResult() != nil {}
        }
    }

    /// Fails the transport closed from an exchange path. Hops through a
    /// detached task so the kill graces keep real waits even when the
    /// caller is cancelled: `Task.sleep` throws instantly in a cancelled
    /// task, which would skip every grace and drop a still-running
    /// `Process` (`NSConcreteTask` raises on dealloc while running).
    private func failClosed() async {
        await Task.detached { await self.close() }.value
    }

    /// Discards fd bytes through the next newline, leaving post-newline
    /// bytes in `pending`. True when framing is whole again: either a
    /// newline was found, or EOF arrived (pending emptied). False when the
    /// fd broke mid-drain. Scanned bytes drop as they prove newline-free,
    /// so the buffer never holds more than one chunk however much the child
    /// streams. Internal (like `readFramedLine`) so the fd-error arm is
    /// directly testable: no public path retires an fd mid-drain on
    /// command.
    func drainToNewline(fd: Int32) async -> Bool {
        var buffer = Data()
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                pending = Data(buffer[buffer.index(after: newline)...])
                return true
            }
            buffer.removeAll(keepingCapacity: true)
            let chunk: Data?
            do {
                chunk = try await Self.readChunk(fd: fd)
            } catch {
                return false
            }
            guard let chunk else {
                pending = Data()
                return true
            }
            buffer = chunk
        }
    }

    /// Reads one `\n`-terminated reply line, carrying over-read bytes in
    /// `pending` for the next call. EOF with no pending bytes is a clean
    /// close; EOF with a partial line is a torn frame. The fd arrives
    /// captured (see `send`).
    private func readReplyLine(fd: Int32) async throws -> Data {
        let framed = try await Self.readFramedLine(from: pending) {
            try await Self.readChunk(fd: fd)
        }
        pending = framed.rest
        return framed.line
    }

    /// Frames one `\n`-terminated reply line from `initial` plus `nextChunk`
    /// pulls, returning the line and the over-read rest. Pure over its
    /// inputs: tests script every path deterministically, while production
    /// passes the fd reader. EOF with an empty buffer is a clean close; EOF
    /// with a partial line is a torn frame. Empty chunks are tolerated (the
    /// fd reader never produces them; `read(2)` returns nil at EOF).
    static func readFramedLine(
        from initial: Data,
        nextChunk: () async throws -> Data?
    ) async throws -> (line: Data, rest: Data) {
        var buffer = initial
        var line = Data()
        var rest = Data()
        var done = false
        while done == false {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let found = buffer[..<newline]
                guard found.count <= MCPMessageEnvelope.maximumBytes else {
                    throw MCPTransportError.malformedEnvelope
                }
                line = Data(found)
                rest = Data(buffer[buffer.index(after: newline)...])
                done = true
            } else {
                guard buffer.count <= MCPMessageEnvelope.maximumBytes else {
                    throw MCPTransportError.malformedEnvelope
                }
                let chunk: Data?
                do {
                    chunk = try await nextChunk()
                } catch {
                    throw MCPTransportError.transportClosed
                }
                guard let chunk else {
                    if buffer.isEmpty {
                        throw MCPTransportError.transportClosed
                    }
                    throw MCPTransportError.malformedEnvelope
                }
                buffer.append(chunk)
            }
        }
        return (line, rest)
    }

    /// Always-close teardown: idempotent, total, never throws. Closes the
    /// child's stdin (EOF for well-behaved servers), waits a grace for a
    /// natural exit, then `SIGTERM`, then `SIGKILL`, records the status,
    /// and drops the pipes (stdout via the dev-null redirect, never a bare
    /// close under a parked reader). Mirrors the oracle `finally`
    /// (mcp.ts:357-360), which closes the transport then the server
    /// unconditionally.
    public func close() async {
        guard didClose == false else { return }
        didClose = true
        guard let taken = live else { return }
        live = nil
        taken.stdinWrite.closeFile()
        if await exitedSoon(taken.process, graceMs: Self.terminateGraceMs) == false {
            taken.process.terminate()
            if await exitedSoon(taken.process, graceMs: Self.killGraceMs) == false {
                kill(taken.process.processIdentifier, SIGKILL)
                _ = await exitedSoon(taken.process, graceMs: Self.killGraceMs)
            }
        }
        status = taken.process.terminationStatus
        Self.invalidateForReading(taken.stdoutRead)
    }

    /// Waits for the child's exit status. Nil when never spawned; the
    /// recorded status after close. Total: ignores cancellation, matching
    /// the always-close ethos. Reaping rides on `Process` deinit; a
    /// transient zombie may show between exit and `close`.
    public func waitForExit() async -> Int32? {
        if let status { return status }
        guard let taken = live else { return nil }
        while taken.process.isRunning {
            try? await Task.sleep(nanoseconds: Self.pollStepNanoseconds)
        }
        let exited = taken.process.terminationStatus
        status = exited
        return exited
    }

    /// The `MCPStdioChannel` pipe seam: `send` as a shared closure.
    public nonisolated var exchange: @Sendable (Data) async throws -> Data {
        { [self] frame in try await self.send(frame) }
    }

    /// True for absolute paths that are executable files. Relative paths
    /// are rejected: no ambient `PATH` lookup across the spawn boundary.
    static func isAbsoluteExecutablePath(_ path: String) -> Bool {
        path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Reads one pipe chunk off the actor: `read(2)` parks a detached
    /// thread instead of the actor, so `close` can land mid-read and fail
    /// it (`EBADF` for the parked read, EOF once the fd points at dev-null).
    /// Nil at EOF.
    static func readChunk(fd: Int32) async throws -> Data? {
        try await Task.detached { try Self.readChunkSync(fd: fd) }.value
    }

    /// Retires a stdout read end: the fd is first redirected to dev-null,
    /// so every parked or future `read(2)` on it returns at once (`EBADF`
    /// for the parked one, EOF after the redirect) instead of blocking,
    /// and only then closed. A bare close would free the fd number while a
    /// detached `readChunk` is still parked on it; any concurrent `open`
    /// reusing that number would feed the parked read foreign bytes (or
    /// park it forever on an unreadable fd). Stdin needs no retire: writes
    /// run in the exchange child task, so `close` can land mid-write, but
    /// a parked `write(2)` holds its open file description (single syscall,
    /// never re-issued), and the kill fails it with EPIPE while the read
    /// end retires — the exchange then fails closed. The handle must be
    /// open and is retired exactly once (`close` guarantees both).
    /// `nullPath` is injectable so tests can cover the open-failure
    /// fallback, a plain close.
    static func invalidateForReading(_ handle: FileHandle, nullPath: String = "/dev/null") {
        // `FileHandle` (not a raw `open`) so the actor's own `close()`
        // never shadows the fd cleanup below.
        if let nullHandle = FileHandle(forReadingAtPath: nullPath) {
            dup2(nullHandle.fileDescriptor, handle.fileDescriptor)
            try? nullHandle.close()
        }
        handle.closeFile()
    }

    /// One blocking `read(2)`: bytes, nil at EOF, or throw on error. No
    /// `EINTR` retry: the host installs no interrupting signal handlers
    /// (dispatch sources observe ignored signals), so interruption is a
    /// genuine close, not a blip.
    static func readChunkSync(fd: Int32) throws -> Data? {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { storage.deallocate() }
        let result = read(fd, storage, Self.chunkSize)
        if result > 0 { return Data(bytes: storage, count: result) }
        if result == 0 { return nil }
        throw MCPTransportError.transportClosed
    }

    /// True when the child exits within the grace. Never blocks a thread:
    /// polls `isRunning` on the actor without holding it hostage.
    private func exitedSoon(_ process: Process, graceMs: Int) async -> Bool {
        var waited = 0
        while process.isRunning && waited < graceMs {
            try? await Task.sleep(nanoseconds: Self.pollStepNanoseconds)
            waited += 5
        }
        return process.isRunning == false
    }
}

/// Spawn specification for one stdio MCP server child.
public struct MCPStdioProcessSpawn: Hashable, Sendable {
    /// Absolute executable path. Relative paths are rejected at spawn.
    public var executablePath: String
    /// Child arguments.
    public var arguments: [String]
    /// Exact child environment, never inherited: the daemon's own
    /// environment is withheld (e2e `stdio-mcp.test.ts`: "env stored as a
    /// secret and the daemon's own environment withheld"). Defaults to a
    /// minimal `PATH`/`LANG`/`LC_ALL` set; callers add configured secrets.
    public var environment: [String: String]

    /// Minimal withheld-by-default environment.
    public static let minimalEnvironment = [
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
    ]

    /// Assembles one spawn specification.
    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = MCPStdioProcessSpawn.minimalEnvironment
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}

/// Spawn failure. Labels only; never paths or environments.
public enum MCPStdioProcessError: Error, Sendable, Equatable, Hashable {
    /// A second spawn, or a spawn after close: the handle is single-shot.
    case alreadySpawned
    /// The executable path is unusable or the spawn threw.
    case spawnFailed
}

// MARK: - Stdio lifetime (runMcpStdioServer waitForExit + finally)

/// Why a stdio lifetime ended. Ports the oracle `waitForExit`
/// once-listeners: `SIGINT` / `SIGTERM` / stdin `end` / stdin `close`
/// (mcp.ts:338-351).
public enum MCPStdioExitReason: String, Sendable, Equatable, Hashable {
    /// `SIGINT` arrived.
    case interrupted
    /// `SIGTERM` arrived.
    case terminated
    /// Standard input reached EOF.
    case stdinEnded
    /// Standard input is not an open file at all.
    case stdinClosed
}

/// How long a stdio server stays up. The `waitForExit` closure is total:
/// it always produces a reason, never throws, so `serve` always closes.
public struct MCPStdioLifetime: Sendable {
    /// Waits for the first exit reason. Total.
    public var waitForExit: @Sendable () async -> MCPStdioExitReason

    /// Serves lifetimes through `waitForExit`.
    public init(waitForExit: @escaping @Sendable () async -> MCPStdioExitReason) {
        self.waitForExit = waitForExit
    }

    /// A scripted lifetime that exits immediately with `reason`.
    public static func scripted(_ reason: MCPStdioExitReason) -> MCPStdioLifetime {
        MCPStdioLifetime(waitForExit: { reason })
    }

    /// The live lifetime: first of `SIGINT`, `SIGTERM`, stdin EOF, or an
    /// already-closed stdin wins, mirroring the oracle once-listeners.
    /// Signal dispositions are restored before `waitForExit` returns.
    public static func live(
        stdinFD: Int32 = STDIN_FILENO,
        devNullPath: String = "/dev/null",
        backoffMs: UInt64 = 100
    ) -> MCPStdioLifetime {
        MCPStdioLifetime(waitForExit: {
            await MCPStdioExitMonitor.firstReason(stdinFD: stdinFD, devNullPath: devNullPath, backoffMs: backoffMs)
        })
    }
}

/// Runs one spawned stdio child until the lifetime ends, then always
/// closes it. Mirrors the oracle `runMcpStdioServer` shape
/// (`connect` -> `waitForExit` -> `finally` close, mcp.ts:332-360): the
/// spawn (done by the caller) is the connect, and the close is
/// unconditional because `waitForExit` is total.
public enum MCPStdioRunner {
    /// Serves `process` until `lifetime` ends, always closes it, and
    /// returns why it ended.
    public static func serve(process: MCPStdioProcess, lifetime: MCPStdioLifetime) async -> MCPStdioExitReason {
        let reason = await lifetime.waitForExit()
        await process.close()
        return reason
    }
}

/// Live exit monitor: signal sources plus a stdin EOF watcher behind an
/// exactly-once latch. First reason wins; the rest drop, mirroring the
/// oracle `finish` removing every listener before resolving.
enum MCPStdioExitMonitor {
    /// Waits for the first exit reason on `stdinFD`. An `fstat` failure
    /// means the fd is already closed; `/dev/null` (which reports phantom
    /// readability but always reads EOF) means ended; anything else arms
    /// the signal sources plus, for monitorable fds, the stdin watcher.
    static func firstReason(stdinFD: Int32, devNullPath: String, backoffMs: UInt64) async -> MCPStdioExitReason {
        var stdinStatus = stat()
        guard fstat(stdinFD, &stdinStatus) == 0 else { return .stdinClosed }
        if Self.isDevNull(stdinStatus, nullPath: devNullPath) { return .stdinEnded }
        let queue = DispatchQueue(label: "rv.mcp-stdio-lifetime")
        let latch = MCPStdioExitLatch()
        // Built before the signal dispositions flip, so the ignore-to-resume
        // window below holds only two source creations: a signal landing
        // there is discarded by the ignore disposition and lost.
        let watcher: MCPStdioStdinWatcher?
        if Self.stdinIsMonitorable(stdinStatus) {
            watcher = MCPStdioStdinWatcher(fd: stdinFD, queue: queue, backoffMs: backoffMs) {
                latch.finish(.stdinEnded)
            }
        } else {
            watcher = nil
        }
        let previousINT = signal(SIGINT, SIG_IGN)
        let previousTERM = signal(SIGTERM, SIG_IGN)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        intSource.setEventHandler { latch.finish(.interrupted) }
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler { latch.finish(.terminated) }
        // Arm-before-resume: the continuation is installed before any source
        // can fire, so a signal or EOF landing in the setup window is
        // delivered instead of dropped. A finish before arm would vanish
        // (the latch holds no continuation yet) and hang the lifetime until
        // the next event, which may never come.
        let reason = await withCheckedContinuation { continuation in
            latch.arm(continuation)
            intSource.resume()
            termSource.resume()
            watcher?.start()
        }
        if let watcher { watcher.teardown() }
        intSource.cancel()
        termSource.cancel()
        _ = signal(SIGINT, previousINT)
        _ = signal(SIGTERM, previousTERM)
        return reason
    }

    /// True when the stdin file is `/dev/null` itself (same device and
    /// inode). `nullPath` is injectable so tests can fail the stat arm.
    static func isDevNull(_ stdinStatus: stat, nullPath: String) -> Bool {
        var nullStatus = stat()
        guard stat(nullPath, &nullStatus) == 0 else { return false }
        return (stdinStatus.st_dev, stdinStatus.st_ino) == (nullStatus.st_dev, nullStatus.st_ino)
    }

    /// True for fd types whose EOF is observable without consuming bytes:
    /// pipes, sockets, and character devices. Regular files never signal
    /// EOF through readability (their offset never advances), so they are
    /// left unmonitored and the lifetime rests on signals alone.
    static func stdinIsMonitorable(_ status: stat) -> Bool {
        switch status.st_mode & S_IFMT {
        case S_IFIFO, S_IFSOCK, S_IFCHR:
            return true
        default:
            return false
        }
    }
}

/// Exactly-once fan-in for exit sources. The first reason wins; later
/// ones drop.
final class MCPStdioExitLatch: Sendable {
    private let box = Mutex<CheckedContinuation<MCPStdioExitReason, Never>?>(nil)

    /// Arms the latch with the waiter's continuation.
    func arm(_ continuation: CheckedContinuation<MCPStdioExitReason, Never>) {
        box.withLock { $0 = continuation }
    }

    /// Delivers `reason` to the waiter, or drops it when another source
    /// already finished.
    func finish(_ reason: MCPStdioExitReason) {
        let taken = box.withLock { current -> CheckedContinuation<MCPStdioExitReason, Never>? in
            let held = current
            current = nil
            return held
        }
        if let taken { taken.resume(returning: reason) }
    }
}

/// Stdin EOF watcher behind a dispatch read source. EOF (zero estimated
/// bytes) finishes at once; data is not an exit, but an unconsumed
/// readable fd refires at ~1MHz, so data cancels the source and revives a
/// fresh one after the backoff, turning the spin into a cheap poll. Every
/// state change is generation-guarded, so teardown and timers interleave
/// safely in either order.
final class MCPStdioStdinWatcher: Sendable {
    private struct State {
        /// Currently armed source. Cancelled sources stay installed until
        /// a fresh revive replaces them, so teardown never branches.
        var source: DispatchSourceRead
        /// Backoff generation: teardown bumps it to stale every timer.
        var generation: UInt64
    }

    private let fd: Int32
    private let queue: DispatchQueue
    private let backoffMs: UInt64
    private let onEOF: @Sendable () -> Void
    private let state: Mutex<State>

    /// Watches `fd` on `queue`, calling `onEOF` once at EOF.
    init(fd: Int32, queue: DispatchQueue, backoffMs: UInt64, onEOF: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.fd = fd
        self.queue = queue
        self.backoffMs = backoffMs
        self.onEOF = onEOF
        self.state = Mutex(State(source: source, generation: 0))
        source.setEventHandler { [self] in self.handleActivity() }
    }

    /// Arms the watcher.
    func start() {
        state.withLock { $0.source.resume() }
    }

    /// Drops the generation and cancels the armed source. Safe during a
    /// backoff: `cancel` on a cancelled source is a no-op, and the
    /// pending timer goes stale.
    func teardown() {
        state.withLock { current in
            current.generation += 1
            current.source.cancel()
        }
    }

    /// Handles one readability event: EOF finishes, data backs off.
    func handleActivity() {
        let pending = state.withLock { $0.source.data }
        if pending == 0 {
            onEOF()
        } else {
            backoff()
        }
    }

    /// Cancels the spinning source and schedules a fresh revive.
    func backoff() {
        let generation = state.withLock { current -> UInt64 in
            current.generation += 1
            current.source.cancel()
            return current.generation
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(backoffMs))) { [self, generation] in
            self.maybeRevive(generation: generation)
        }
    }

    /// Revives a fresh source unless a newer backoff or teardown went
    /// stale first.
    func maybeRevive(generation: UInt64) {
        let fresh = state.withLock { $0.generation == generation }
        if fresh == false { return }
        let revived = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        revived.setEventHandler { [self] in self.handleActivity() }
        state.withLock {
            $0.source = revived
            $0.source.resume()
        }
    }
}
