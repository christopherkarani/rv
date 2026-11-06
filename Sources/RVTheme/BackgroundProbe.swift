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

/// The live channel: stdin for replies, stdout for the request. Puts stdin
/// in non-canonical, no-echo mode only for the exchange and restores the
/// saved termios on every path out.
public struct StandardTerminalChannel: TerminalQueryChannel {
    public var input: Int32
    public var output: Int32

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.input = input
        self.output = output
    }

    public func exchange(_ request: [UInt8], timeout: Duration, isComplete: ([UInt8]) -> Bool) -> [UInt8]? {
        guard isatty(input) == 1, isatty(output) == 1 else { return nil }
        var saved = termios()
        guard tcgetattr(input, &saved) == 0 else { return nil }
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        guard tcsetattr(input, TCSANOW, &raw) == 0 else { return nil }
        defer { _ = tcsetattr(input, TCSANOW, &saved) }

        var written = 0
        while written < request.count {
            let count = request[written...].withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            written += count
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var reply: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while isComplete(reply) == false {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            let milliseconds = Int32(clamping: remaining.components.seconds * 1_000
                + remaining.components.attoseconds / 1_000_000_000_000_000 + 1)
            var ready = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, milliseconds)
            if polled < 0, errno == EINTR { continue }
            guard polled > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            reply += buffer[..<count]
        }
        return reply
    }
}
