#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A hidden one-line prompt on a terminal: the value `rv secrets set` reads
/// when stdin is a terminal. macOS uses `readpassphrase(3)`; Linux has no
/// `readpassphrase`, so `read(fd:prompt:maximumBytes:)` does the same job on
/// the terminal fd directly.
///
/// The terminal is put in non-canonical mode with echo and signals off, and
/// its attributes are restored before returning on every path. With signals
/// off, Ctrl-C and Ctrl-D are bytes, read here as cancel, so an interrupt
/// never leaves the terminal silent. A SIGTERM, SIGHUP, SIGINT or SIGQUIT
/// sent from elsewhere restores the terminal too, then gets its previous
/// action, as `readpassphrase(3)` does. Backspace and Ctrl-U edit the line;
/// Enter ends it. The prompt and the closing newline go to the same fd.
enum HiddenLinePrompt {
    enum Outcome: Equatable {
        case line(Data)
        /// Ctrl-C, Ctrl-D on an empty line, or end of input.
        case cancelled
        /// Not a terminal, or its attributes could not be set.
        case unavailable
    }

    /// Opens the controlling terminal and reads one hidden line from it.
    static func readFromTerminal(prompt: String, maximumBytes: Int) -> Outcome {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        return read(fd: fd, prompt: prompt, maximumBytes: maximumBytes)
    }

    /// Reads one hidden line from the terminal `fd`. Input past
    /// `maximumBytes` is read to the end of the line and kept to
    /// `maximumBytes + 1` bytes, so the caller can refuse it as too long.
    static func read(fd: Int32, prompt: String, maximumBytes: Int) -> Outcome {
        guard isatty(fd) == 1 else { return .unavailable }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return .unavailable }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
        setControlCharacter(&hidden, VMIN, 1)
        setControlCharacter(&hidden, VTIME, 0)
        // TCSAFLUSH drops what was typed ahead, which the terminal echoed.
        HiddenLineSignals.arm(fd: fd, saved: original)
        defer { HiddenLineSignals.disarm() }
        guard setAttributes(fd, &hidden, when: TCSAFLUSH) else { return .unavailable }
        writeAll(fd, Array(prompt.utf8))
        var line: [UInt8] = []
        line.reserveCapacity(min(maximumBytes + 1, 4096))
        let outcome = readLine(fd: fd, into: &line, maximumBytes: maximumBytes)
        _ = setAttributes(fd, &original, when: TCSANOW)
        writeAll(fd, Array("\n".utf8))
        defer { for index in line.indices { line[index] = 0 } }
        return outcome ? .line(Data(line)) : .cancelled
    }

    /// True on Enter; false on cancel or end of input.
    private static func readLine(fd: Int32, into line: inout [UInt8], maximumBytes: Int) -> Bool {
        var byte: UInt8 = 0
        while true {
            let count = readByte(fd, &byte)
            // A signal whose previous action returned: the terminal is
            // already back, so the line is cancelled.
            if HiddenLineSignals.caught != 0 { return false }
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return false }
            switch byte {
            case 0x0A, 0x0D:
                return true
            case 0x03:
                return false
            case 0x04:
                if line.isEmpty { return false }
            case 0x7F, 0x08:
                // Drop one UTF-8 character: its continuation bytes, then its lead.
                while let last = line.last, last & 0xC0 == 0x80 { line.removeLast() }
                if line.isEmpty == false { line.removeLast() }
            case 0x15:
                for index in line.indices { line[index] = 0 }
                line.removeAll(keepingCapacity: true)
            default:
                if line.count <= maximumBytes { line.append(byte) }
            }
        }
    }

    private static func readByte(_ fd: Int32, _ byte: inout UInt8) -> Int {
        withUnsafeMutableBytes(of: &byte) { buffer in
            #if canImport(Darwin)
            Darwin.read(fd, buffer.baseAddress, 1)
            #else
            Glibc.read(fd, buffer.baseAddress, 1)
            #endif
        }
    }

    private static func setAttributes(_ fd: Int32, _ term: inout termios, when: Int32) -> Bool {
        while tcsetattr(fd, when, &term) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }

    private static func setControlCharacter(_ term: inout termios, _ index: Int32, _ value: cc_t) {
        withUnsafeMutableBytes(of: &term.c_cc) { buffer in
            buffer[Int(index)] = value
        }
    }
}

/// The terminal attributes to put back if a signal ends the prompt. The
/// handler only calls async-signal-safe functions: `tcsetattr`,
/// `sigaction` and `raise`.
private enum HiddenLineSignals {
    nonisolated(unsafe) static var fd: Int32 = -1
    nonisolated(unsafe) static var saved = termios()
    nonisolated(unsafe) static var caught: sig_atomic_t = 0
    nonisolated(unsafe) static var previousTERM = sigaction()
    nonisolated(unsafe) static var previousHUP = sigaction()
    nonisolated(unsafe) static var previousINT = sigaction()
    nonisolated(unsafe) static var previousQUIT = sigaction()

    static func arm(fd: Int32, saved: termios) {
        self.fd = fd
        self.saved = saved
        caught = 0
        previousTERM = install(SIGTERM)
        previousHUP = install(SIGHUP)
        previousINT = install(SIGINT)
        previousQUIT = install(SIGQUIT)
    }

    static func disarm() {
        restore(SIGTERM, previousTERM)
        restore(SIGHUP, previousHUP)
        restore(SIGINT, previousINT)
        restore(SIGQUIT, previousQUIT)
        fd = -1
    }

    private static func install(_ number: Int32) -> sigaction {
        var action = sigaction()
        var previous = sigaction()
        #if canImport(Darwin)
        action.__sigaction_u.__sa_handler = handle
        #else
        action.__sigaction_handler.sa_handler = handle
        #endif
        sigemptyset(&action.sa_mask)
        // No SA_RESTART: the blocked `read` returns EINTR if the previous
        // action lets the process live.
        action.sa_flags = 0
        sigaction(number, &action, &previous)
        return previous
    }

    private static func restore(_ number: Int32, _ previous: sigaction) {
        var copy = previous
        sigaction(number, &copy, nil)
    }

    private static let handle: @convention(c) (Int32) -> Void = { number in
        caught = 1
        if fd >= 0 {
            var copy = saved
            while tcsetattr(fd, TCSANOW, &copy) != 0 && errno == EINTR {}
        }
        // Hand the signal to what was there before (default: terminate).
        var previous: sigaction
        switch number {
        case SIGTERM: previous = previousTERM
        case SIGHUP: previous = previousHUP
        case SIGINT: previous = previousINT
        default: previous = previousQUIT
        }
        sigaction(number, &previous, nil)
        raise(number)
    }
}
