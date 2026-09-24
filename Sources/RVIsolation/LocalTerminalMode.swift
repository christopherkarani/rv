#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Saved attributes for the caller's terminal.
///
/// Raw mode is local to the proving client. It is not the runtime's PTY.
/// `restore()` is safe to call more than once, including after a normal
/// exit, a protocol error, or a signal that the client handles.
public final class LocalTerminalRestorer: Sendable {
    private let fd: Int32
    private let saved: termios
    private let active = Mutex(true)
    private let installSignals: Bool

    private init(fd: Int32, saved: termios, installSignals: Bool) {
        self.fd = fd
        self.saved = saved
        self.installSignals = installSignals
    }

    /// Puts `fd` in raw mode when it is a terminal. Returns nil otherwise.
    /// A second engage while the signal handler is live returns nil and does
    /// not replace the termios that handler will restore.
    public static func engage(_ fd: Int32, signals: Bool = true) -> LocalTerminalRestorer? {
        guard isatty(fd) == 1 else { return nil }
        if signals, LocalTerminalSignal.isArmed { return nil }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        // Raw mode clears ISIG. The proving client still wants Ctrl-C to
        // raise SIGINT so the handler can put the local terminal back.
        // The runtime's own PTY keeps ISIG separately and receives 0x03
        // only when a client writes that byte.
        if signals {
            raw.c_lflag |= tcflag_t(ISIG)
        }
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else { return nil }
        let restorer = LocalTerminalRestorer(fd: fd, saved: original, installSignals: signals)
        if signals {
            LocalTerminalSignal.arm(fd: fd, saved: original)
        }
        return restorer
    }

    /// Blocks the signals `engage` handles. Call this on a thread that reads
    /// the terminal, so the handler does not run inside that `read`.
    public static func blockInterruptSignalsInThisThread() {
        LocalTerminalSignal.blockInReaderThread()
    }

    public func restore() {
        guard active.withLock({ $0 }) else { return }
        guard applySavedTermios(saved, fd: fd) else { return }
        active.withLock { $0 = false }
        if installSignals {
            LocalTerminalSignal.disarm(fd: fd)
        }
    }

    /// Restores the attributes the signal handler would restore, without exiting.
    func restoreInstalledSignal() {
        LocalTerminalSignal.restoreArmedTerminal()
    }

    deinit {
        restore()
    }
}

/// `PENDIN` (`0x20000000`) is set when `ICANON` turns on under `TCSANOW`
/// or `TCSADRAIN`, then OR'd back onto every later local-flag write.
/// `TCSAFLUSH` (`TIOCSETAF`) is the command that does not set it. The
/// termios passed in already has the bit off. There is no `tcgetattr`.
private let termiosPendin = tcflag_t(0x2000_0000)

private func applySavedTermios(_ saved: termios, fd: Int32) -> Bool {
    var copy = saved
    copy.c_lflag &= ~termiosPendin
    return writeTermios(fd, &copy)
}

private func writeTermios(_ fd: Int32, _ term: inout termios) -> Bool {
    // `TCSAFLUSH` waits until the other side of a PTY reads pending output.
    // A client that still owns the master blocks there, so the process never
    // exits and the terminal stays raw. `TCSANOW` applies immediately.
    while tcsetattr(fd, TCSANOW, &term) != 0 {
        if errno != EINTR { return false }
    }
    return true
}

public struct LocalTerminalWindow: Sendable, Equatable {
    public var rows: Int
    public var columns: Int

    public static func current(fd: Int32) -> LocalTerminalWindow? {
        guard isatty(fd) == 1 else { return nil }
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { return nil }
        let rows = Int(size.ws_row)
        let columns = Int(size.ws_col)
        guard TerminalStreamLimits.accepts(rows: rows, columns: columns) else { return nil }
        return LocalTerminalWindow(rows: rows, columns: columns)
    }
}

private enum LocalTerminalSignal {
    nonisolated(unsafe) static var saved = termios()
    nonisolated(unsafe) static var fd: Int32 = -1
    nonisolated(unsafe) static var armed: sig_atomic_t = 0
    nonisolated(unsafe) static var previousINT = sigaction()
    nonisolated(unsafe) static var previousTERM = sigaction()
    nonisolated(unsafe) static var previousHUP = sigaction()
    nonisolated(unsafe) static var previousQUIT = sigaction()

    static var isArmed: Bool { armed != 0 }

    static func arm(fd: Int32, saved: termios) {
        if armed != 0 { return }
        self.fd = fd
        self.saved = saved
        armed = 1
        previousINT = install(SIGINT)
        previousTERM = install(SIGTERM)
        previousHUP = install(SIGHUP)
        previousQUIT = install(SIGQUIT)
        // Swift blocks these on the threads it creates. Leave them unblocked
        // on the thread that armed the handler so the signal can be delivered.
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGINT)
        sigaddset(&set, SIGTERM)
        sigaddset(&set, SIGHUP)
        sigaddset(&set, SIGQUIT)
        pthread_sigmask(SIG_UNBLOCK, &set, nil)
    }

    static func disarm(fd: Int32) {
        guard self.fd == fd else { return }
        armed = 0
        self.fd = -1
        restoreAction(SIGINT, previousINT)
        restoreAction(SIGTERM, previousTERM)
        restoreAction(SIGHUP, previousHUP)
        restoreAction(SIGQUIT, previousQUIT)
    }

    /// Restores the saved mode without exiting. The signal handler does not
    /// call this: it only `tcsetattr`s the copied termios.
    static func restoreArmedTerminal() {
        guard armed != 0 else { return }
        _ = applySavedTermios(saved, fd: fd)
    }

    /// The stdin reader blocks in `read`. A handler that calls `tcsetattr` on
    /// that thread deadlocks on the tty lock, so that thread blocks these
    /// signals and the handler runs elsewhere.
    static func blockInReaderThread() {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGINT)
        sigaddset(&set, SIGTERM)
        sigaddset(&set, SIGHUP)
        sigaddset(&set, SIGQUIT)
        pthread_sigmask(SIG_BLOCK, &set, nil)
    }

    private static func install(_ number: Int32) -> sigaction {
        var action = sigaction()
        var previous = sigaction()
        action.__sigaction_u.__sa_handler = handle
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(number, &action, &previous)
        return previous
    }

    private static func restoreAction(_ number: Int32, _ previous: sigaction) {
        var copy = previous
        sigaction(number, &copy, nil)
    }

    /// One `TCSAFLUSH` of the copied termios, with `PENDIN` off.
    /// `TCSANOW` would set that bit again on the way back to `ICANON`.
    /// No `tcgetattr`.
    private static let handle: @convention(c) (Int32) -> Void = { _ in
        if armed != 0, fd >= 0 {
            var copy = saved
            copy.c_lflag &= ~tcflag_t(0x2000_0000)
            while tcsetattr(fd, TCSANOW, &copy) != 0 && errno == EINTR {}
        }
        _exit(1)
    }
}

public enum WorkspaceTerminalDriveError: Error, Equatable {
    case exited(Int32)
    case client(WorkspaceClientFailure)
}

/// Proving client for `rv workspace run`. Restores the local terminal before
/// it returns or throws. The runtime PTY is a different descriptor.
public enum WorkspaceTerminalDriver {
    public static func drive(
        client: WorkspaceClient,
        runtime: UUID,
        rows: Int,
        columns: Int,
        input: Int32,
        output: FileHandle,
        restorer: LocalTerminalRestorer?
    ) throws {
        let previousPipe = ignoreSIGPIPE()
        let bridge = TerminalStdinBridge(client: client, runtime: runtime, input: input)
        bridge.start()
        defer {
            // The reader blocks in `read`. Closing that descriptor from the
            // caller waits behind it, and a pending read makes restore set
            // PENDIN. Stop the reader before either of those.
            bridge.stop()
            restorer?.restore()
            restoreSIGPIPE(previousPipe)
        }
        var currentRows = rows
        var currentColumns = columns
        while true {
            if bridge.didEnd {
                // Output copied onto this PTY can come back as stdin and end
                // the bridge before the exit event is read. Take that event
                // before returning.
                switch client.nextTerminalEvent(timeout: 0.5) {
                case .failure(let error):
                    _ = client.detach()
                    throw WorkspaceTerminalDriveError.client(error)
                case .success(.event(let event)) where event.runtime == runtime:
                    if case .exited(let status) = event.body {
                        _ = client.detach()
                        throw WorkspaceTerminalDriveError.exited(status)
                    }
                    _ = client.detach()
                    return
                case .success:
                    _ = client.detach()
                    return
                }
            }
            if let size = LocalTerminalWindow.current(fd: output.fileDescriptor),
                size.rows != currentRows || size.columns != currentColumns
            {
                currentRows = size.rows
                currentColumns = size.columns
                _ = client.resizeTerminal(runtime, rows: size.rows, columns: size.columns)
            }
            switch client.nextTerminalEvent(timeout: 0.2) {
            case .failure(let error):
                _ = client.detach()
                throw WorkspaceTerminalDriveError.client(error)
            case .success(.waiting):
                continue
            case .success(.event(let event)):
                guard event.runtime == runtime else { continue }
                switch event.body {
                case .replay(_, let bytes), .output(_, let bytes):
                    guard writeOutput(output.fileDescriptor, bytes) else {
                        throw WorkspaceTerminalDriveError.client(.disconnected)
                    }
                case .exited(let status):
                    // Workspace close kills the child, so the signal status
                    // can arrive before `workspaceClosed`. The close is the
                    // failure the driver must report.
                    switch client.nextTerminalEvent(timeout: 0.3) {
                    case .failure(let error) where error == .workspaceClosed || error == .disconnected:
                        _ = client.detach()
                        throw WorkspaceTerminalDriveError.client(error)
                    case .failure, .success:
                        break
                    }
                    _ = client.detach()
                    throw WorkspaceTerminalDriveError.exited(status)
                case .overflow:
                    _ = client.detach()
                    throw WorkspaceTerminalDriveError.client(.terminalLimit)
                case .inputOwner:
                    break
                }
            }
        }
    }

    private static func writeOutput(_ fd: Int32, _ bytes: Data) -> Bool {
        let raw = [UInt8](bytes)
        var offset = 0
        while offset < raw.count {
            let count = raw.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
}

private func ignoreSIGPIPE() -> sigaction {
    var action = sigaction()
    var previous = sigaction()
    action.__sigaction_u.__sa_handler = SIG_IGN
    sigemptyset(&action.sa_mask)
    action.sa_flags = 0
    sigaction(SIGPIPE, &action, &previous)
    return previous
}

private func restoreSIGPIPE(_ previous: sigaction) {
    var copy = previous
    sigaction(SIGPIPE, &copy, nil)
}

/// Reads one file descriptor on `rv-terminal-stdin` and writes those bytes
/// to the runtime. `rv workspace run` and the proving driver share this type
/// so the CLI module stays free of classes.
public final class TerminalStdinBridge: Sendable {
    private let client: WorkspaceClient
    private let runtime: UUID
    private let input: Int32
    private let state = Mutex<State>(State())
    private let stopped = DispatchGroup()

    private struct State {
        var ended = false
        var stopRequested = false
        var readerStopped = false
    }

    public init(client: WorkspaceClient, runtime: UUID, input: Int32) {
        self.client = client
        self.runtime = runtime
        self.input = input
        stopped.enter()
    }

    public convenience init(client: WorkspaceClient, runtime: UUID) {
        self.init(client: client, runtime: runtime, input: STDIN_FILENO)
    }

    public var didEnd: Bool {
        state.withLock { $0.ended }
    }

    public var inputEnded: Bool { didEnd }

    public func start() {
        let bridge = self
        let thread = Thread {
            bridge.read()
        }
        thread.name = "rv-terminal-stdin"
        thread.start()
    }

    /// Wakes a blocked `read` so the caller can close `input` and restore
    /// the terminal. Waits until that loop has left the descriptor.
    public func stop() {
        state.withLock { $0.stopRequested = true }
        // Bounded like the old condition wait: proceed to drain even if the
        // reader never started or is stuck in `read`.
        _ = stopped.wait(timeout: .now() + 2)
        // `TCSAFLUSH` waits for the slave output queue. On a PTY that queue
        // is this master, and nothing else is reading it once the loop stops.
        drainInput()
    }

    private func drainInput() {
        let flags = fcntl(input, F_GETFL)
        guard flags >= 0 else { return }
        guard fcntl(input, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count > 0 { continue }
            break
        }
        _ = fcntl(input, F_SETFL, flags)
    }

    private func read() {
        LocalTerminalRestorer.blockInterruptSignalsInThisThread()
        var buffer = [UInt8](repeating: 0, count: TerminalStreamLimits.maximumInputBytes)
        var fds = [pollfd(fd: input, events: Int16(POLLIN), revents: 0)]
        defer { markReaderStopped() }
        while shouldStop() == false {
            fds[0].revents = 0
            let ready = poll(&fds, 1, 50)
            if shouldStop() { return }
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                finish()
                return
            }
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 {
                finish()
                return
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                finish()
                return
            }
            let data = Data(buffer.prefix(count))
            if case .failure = client.writeTerminal(runtime, bytes: data) {
                finish()
                return
            }
        }
    }

    private func shouldStop() -> Bool {
        state.withLock { $0.stopRequested }
    }

    private func finish() {
        state.withLock { $0.ended = true }
    }

    /// Only the first call balances the `enter` in `init`, so a double
    /// `start` cannot drive the group count negative.
    private func markReaderStopped() {
        let first = state.withLock { state -> Bool in
            if state.readerStopped { return false }
            state.readerStopped = true
            return true
        }
        if first {
            stopped.leave()
        }
    }
}
#endif
