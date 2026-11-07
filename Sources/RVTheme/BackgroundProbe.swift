#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One request/reply exchange with the controlling terminal. The seam the
/// background probe is tested through.
public protocol TerminalQueryChannel {
    /// Writes `request`, then collects reply bytes until `isComplete` holds
    /// or `timeout` passes. Returns what arrived (possibly empty), or nil
    /// when the terminal could not be used at all. Leaves the terminal in
    /// the state it found it.
    func exchange(_ request: [UInt8], timeout: Duration, isComplete: ([UInt8]) -> Bool) -> [UInt8]?
}

/// A channel with no terminal behind it: every exchange fails, so
/// detection keeps `.dark`. For probes built without live I/O.
public struct UnavailableTerminalChannel: TerminalQueryChannel {
    public init() {}

    public func exchange(_ request: [UInt8], timeout: Duration, isComplete: ([UInt8]) -> Bool) -> [UInt8]? {
        nil
    }
}

public enum BackgroundProbe {
    /// Long enough for a local terminal, short enough that a terminal that
    /// answers nothing costs the user little.
    public static let timeout: Duration = .milliseconds(100)

    /// True inside an SSH session. A round trip there can outlast any
    /// sensible timeout, and a reply that lands after the probe gave up
    /// would be typed into the shell, so remote terminals are never asked.
    public static func isRemoteSession(environment: [String: String]) -> Bool {
        environment["SSH_TTY"] != nil || environment["SSH_CONNECTION"] != nil
    }

    /// The background to paint for. Asks the terminal only when the
    /// preference is automatic and color will actually be drawn on an
    /// interactive terminal; every other path, and every failure, is
    /// `.dark` (what rv drew before it asked).
    public static func detect(
        preference: ThemePreference,
        terminal: TTYPair,
        forbid: OutputForbid,
        channel: some TerminalQueryChannel
    ) -> TerminalBackground {
        switch preference {
        case .dark:
            return .dark
        case .light:
            return .light
        case .automatic:
            guard terminal.isBrowseEligible, forbid.canCarryColor, forbid.json == false, forbid.robot == false,
                let reply = channel.exchange(
                    BackgroundColorQuery.request, timeout: timeout, isComplete: BackgroundColorQuery.isComplete),
                let color = BackgroundColorQuery.parseReply(reply)
            else { return .dark }
            return color.background
        }
    }
}

/// The terminal operations the live channel needs. Injectable so its
/// job-control, termios, and draining rules are testable without a tty.
public protocol TerminalDevice {
    /// Both the reply and the request end are terminals.
    func isTerminal() -> Bool
    /// This process group owns the terminal. A background job that
    /// changed termios or wrote the query would be stopped by SIGTTOU.
    func isForegroundProcessGroup() -> Bool
    /// Input is already waiting (user typeahead) before anything is asked.
    func hasPendingInput() -> Bool
    func attributes() -> termios?
    /// Applies `attributes` immediately, keeping queued input.
    func setAttributes(_ attributes: termios) -> Bool
    func write(_ bytes: [UInt8]) -> Bool
    func now() -> ContinuousClock.Instant
    /// One input byte, waiting at most `timeout`; nil on timeout, EOF, or
    /// error.
    func readByte(within timeout: Duration) -> UInt8?
}

/// The live channel: stdin for replies, stdout for the request.
///
/// Asks only from the foreground process group and only when no typeahead
/// is queued. Puts stdin in non-canonical, no-echo, no-signal mode for the
/// exchange (so Ctrl-C cannot kill rv while echo is off) and restores the
/// saved termios on every path out.
///
/// Replies are read one byte at a time and reading stops the moment the
/// DA1 reply ends, so anything typed after the reply stays queued for the
/// shell. A reply not finished by `timeout` is still drained for
/// `drainGrace`, and one already started is read to its end, so a slow
/// reply is consumed here instead of landing at the prompt or in a pane.
/// Tradeoff: keys typed between the query and the end of its reply (at
/// most ~250 ms, including Ctrl-C) are read and dropped; they cannot be
/// pushed back without TIOCSTI.
public struct StandardTerminalChannel: TerminalQueryChannel {
    /// Extra time, past the caller's timeout, that a late reply is still
    /// read and consumed. Only a terminal that answers neither query pays
    /// it; nearly every terminal answers DA1, which ends the read at once.
    public static let drainGrace: Duration = .milliseconds(150)
    /// Once a reply has started, the longest wait for its next byte.
    public static let interByteGap: Duration = .milliseconds(20)
    /// More reply than this is not a terminal answering; treat it as none.
    public static let replyLimit = 512

    public var device: any TerminalDevice

    public init(device: any TerminalDevice) {
        self.device = device
    }

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.init(device: SystemTerminalDevice(input: input, output: output))
    }

    public func exchange(_ request: [UInt8], timeout: Duration, isComplete: ([UInt8]) -> Bool) -> [UInt8]? {
        guard device.isTerminal(), device.isForegroundProcessGroup(), let saved = device.attributes() else {
            return nil
        }
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        guard device.setAttributes(raw) else { return nil }
        defer { _ = device.setAttributes(saved) }
        // Checked in raw mode, where a half-typed canonical line is visible.
        guard device.hasPendingInput() == false, device.write(request) else { return nil }

        let deadline = device.now() + timeout + Self.drainGrace
        var reply: [UInt8] = []
        while isComplete(reply) == false {
            guard reply.count < Self.replyLimit else { return [] }
            // A reply already under way is read to its end even past the
            // deadline, as long as its bytes keep coming.
            let remaining = max(device.now().duration(to: deadline), reply.isEmpty ? .zero : Self.interByteGap)
            guard remaining > .zero, let byte = device.readByte(within: remaining) else { break }
            reply.append(byte)
        }
        return reply
    }
}

/// `TerminalDevice` over real file descriptors.
public struct SystemTerminalDevice: TerminalDevice {
    public var input: Int32
    public var output: Int32

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.input = input
        self.output = output
    }

    public func isTerminal() -> Bool {
        isatty(input) == 1 && isatty(output) == 1
    }

    public func isForegroundProcessGroup() -> Bool {
        let owner = tcgetpgrp(input)
        return owner != -1 && owner == getpgrp()
    }

    public func hasPendingInput() -> Bool {
        waitReadable(within: .zero) == 1
    }

    public func attributes() -> termios? {
        var current = termios()
        return tcgetattr(input, &current) == 0 ? current : nil
    }

    public func setAttributes(_ attributes: termios) -> Bool {
        var attributes = attributes
        return tcsetattr(input, TCSANOW, &attributes) == 0
    }

    public func write(_ bytes: [UInt8]) -> Bool {
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { Self.systemWrite(output, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            written += count
        }
        return true
    }

    public func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    public func readByte(within timeout: Duration) -> UInt8? {
        let deadline = now() + timeout
        while true {
            let ready = waitReadable(within: max(now().duration(to: deadline), .zero))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            var byte: UInt8 = 0
            let count = read(input, &byte, 1)
            if count < 0, errno == EINTR { continue }
            return count == 1 ? byte : nil
        }
    }

    /// `select`, not `poll`: macOS `poll` reports `/dev/tty` ready at once
    /// (POLLNVAL) and the read that follows blocks until a key is pressed.
    private func waitReadable(within timeout: Duration) -> Int32 {
        guard input >= 0, input < FD_SETSIZE else { return -1 }
        var readable = fd_set()
        // FD_SET by hand: fd_set is a little-endian bit array on every
        // platform rv builds for, and Swift does not import the macro.
        withUnsafeMutableBytes(of: &readable) { bits in
            bits[Int(input) / 8] |= UInt8(1 << (Int(input) % 8))
        }
        let microseconds = timeout.components.seconds * 1_000_000 + timeout.components.attoseconds / 1_000_000_000_000
        var wait = timeval(tv_sec: .init(microseconds / 1_000_000), tv_usec: .init(microseconds % 1_000_000))
        return select(input + 1, &readable, nil, nil, &wait)
    }

    private static func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #else
        Glibc.write(fd, buffer, count)
        #endif
    }
}
