#if os(macOS)
import Darwin
import Foundation

/// Saved attributes for the caller's terminal.
///
/// Raw mode is local to the proving client. It is not the runtime's PTY.
/// `restore()` is safe to call more than once, including after a normal
/// exit, a protocol error, or a signal that the client handles.
public final class LocalTerminalRestorer: @unchecked Sendable {
    private let fd: Int32
    private var saved: termios
    private var active: Bool
    private let installSignals: Bool

    private init(fd: Int32, saved: termios, installSignals: Bool) {
        self.fd = fd
        self.saved = saved
        self.active = true
        self.installSignals = installSignals
    }

    /// Puts `fd` in raw mode when it is a terminal. Returns nil otherwise.
    public static func engage(_ fd: Int32, signals: Bool = true) -> LocalTerminalRestorer? {
        guard isatty(fd) == 1 else { return nil }
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
        guard active else { return }
        applySavedTermios(saved, fd: fd)
        active = false
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

/// Writes `saved` back, then clears `PENDIN` when the kernel set it.
///
/// Leaving raw mode for the saved canonical mode makes `tcgetattr` report
/// `PENDIN` (`0x20000000`) even though that bit was not in the saved flags.
/// It is a one-shot retype state, not part of the mode. A second
/// `tcsetattr` of the already-canonical attributes drops it, so a later
/// `tcgetattr` matches the mode `engage` captured.
private func applySavedTermios(_ saved: termios, fd: Int32) {
    var copy = saved
    guard tcsetattr(fd, TCSANOW, &copy) == 0 else { return }
    var applied = termios()
    guard tcgetattr(fd, &applied) == 0 else { return }
    let pending = tcflag_t(PENDIN)
    guard (applied.c_lflag & pending) != 0, (saved.c_lflag & pending) == 0 else { return }
    applied.c_lflag &= ~pending
    _ = tcsetattr(fd, TCSANOW, &applied)
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
    nonisolated(unsafe) static var armed: Int32 = 0

    static func arm(fd: Int32, saved: termios) {
        self.fd = fd
        self.saved = saved
        armed = 1
        install(SIGINT)
        install(SIGTERM)
        install(SIGHUP)
        install(SIGQUIT)
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
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
        signal(SIGQUIT, SIG_DFL)
        signal(SIGINT, SIG_DFL)
    }

    /// Same termios restore the signal handler runs before it exits.
    static func restoreArmedTerminal() {
        guard armed != 0 else { return }
        applySavedTermios(saved, fd: fd)
        armed = 0
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

    private static func install(_ number: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = handle
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(number, &action, nil)
    }

    private static let handle: @convention(c) (Int32) -> Void = { _ in
        restoreArmedTerminal()
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
        let bridge = TerminalStdinBridge(client: client, runtime: runtime, input: input)
        bridge.start()
        var currentRows = rows
        var currentColumns = columns
        while true {
            if bridge.didEnd {
                restorer?.restore()
                _ = client.detach()
                return
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
                restorer?.restore()
                _ = client.detach()
                throw WorkspaceTerminalDriveError.client(error)
            case .success(.waiting):
                continue
            case .success(.event(let event)):
                guard event.runtime == runtime else { continue }
                switch event.body {
                case .replay(_, let bytes), .output(_, let bytes):
                    output.write(bytes)
                case .exited(let status):
                    restorer?.restore()
                    _ = client.detach()
                    throw WorkspaceTerminalDriveError.exited(status)
                case .overflow:
                    restorer?.restore()
                    _ = client.detach()
                    throw WorkspaceTerminalDriveError.client(.terminalLimit)
                case .inputOwner:
                    break
                }
            }
        }
    }
}

private final class TerminalStdinBridge: @unchecked Sendable {
    private let client: WorkspaceClient
    private let runtime: UUID
    private let input: Int32
    private let lock = NSLock()
    private var ended = false

    init(client: WorkspaceClient, runtime: UUID, input: Int32) {
        self.client = client
        self.runtime = runtime
        self.input = input
    }

    var didEnd: Bool {
        lock.lock()
        let value = ended
        lock.unlock()
        return value
    }

    func start() {
        let bridge = self
        let thread = Thread {
            bridge.read()
        }
        thread.name = "rv-terminal-stdin"
        thread.start()
    }

    private func read() {
        LocalTerminalRestorer.blockInterruptSignalsInThisThread()
        var buffer = [UInt8](repeating: 0, count: TerminalStreamLimits.maximumInputBytes)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 {
                finish()
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
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

    private func finish() {
        lock.lock()
        ended = true
        lock.unlock()
    }
}
#endif
