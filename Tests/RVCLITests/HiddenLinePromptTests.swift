#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVCLI

/// The hidden prompt `rv secrets set` uses on Linux (macOS has
/// readpassphrase), driven through a pseudo-terminal: the value is read,
/// never echoed, and the terminal is put back.
@Suite("Hidden line prompt", .serialized)
struct HiddenLinePromptTests {
    private final class PTY: @unchecked Sendable {
        let primary: Int32
        let replica: Int32
        private var primaryOpen = true

        init() throws {
            var primary: Int32 = -1
            var replica: Int32 = -1
            guard openpty(&primary, &replica, nil, nil, nil) == 0 else { throw POSIXError(.ENODEV) }
            self.primary = primary
            self.replica = replica
        }

        /// Hangs up the terminal: a read blocked on the replica returns.
        func closePrimary() {
            guard primaryOpen else { return }
            primaryOpen = false
            _ = systemClose(primary)
        }

        func close() {
            closePrimary()
            _ = systemClose(replica)
        }

        func write(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBytes { systemWrite(primary, $0.baseAddress, $0.count) }
        }

        /// Reads what the program wrote to the terminal until `marker`
        /// shows up or a short deadline passes.
        func readOutput(until marker: String) -> String {
            var out: [UInt8] = []
            let deadline = Date().addingTimeInterval(5)
            var buffer = [UInt8](repeating: 0, count: 256)
            while primaryOpen, Date() < deadline {
                var poller = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 100) > 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { systemRead(primary, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                out += buffer.prefix(count)
                if String(decoding: out, as: UTF8.self).contains(marker) { break }
            }
            return String(decoding: out, as: UTF8.self)
        }

        /// True once the prompt has put the terminal in hidden mode.
        func waitForHiddenMode() -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                var current = termios()
                if tcgetattr(replica, &current) == 0, current.c_lflag & tcflag_t(ECHO) == 0 { return true }
                usleep(5_000)
            }
            return false
        }
    }

    /// The prompt's result, filled in by its reader thread.
    private final class Reader: @unchecked Sendable {
        var outcome: HiddenLinePrompt.Outcome?
        var thread: pthread_t?
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)

        /// Runs the prompt on its own thread: a blocking read must not hold
        /// a thread of the shared pool. SIGTERM stays deliverable there.
        func start(fd: Int32) {
            let thread = Thread { [self] in
                self.thread = pthread_self()
                var set = sigset_t()
                sigemptyset(&set)
                sigaddset(&set, SIGTERM)
                pthread_sigmask(SIG_UNBLOCK, &set, nil)
                started.signal()
                outcome = HiddenLinePrompt.read(fd: fd, prompt: "Value for TOKEN: ", maximumBytes: 64)
                done.signal()
            }
            thread.start()
            started.wait()
        }

        /// Waits for the outcome; past the deadline the terminal is hung up
        /// so the reader returns and the test fails instead of hanging.
        func finish(_ pty: PTY) -> Bool {
            if done.wait(timeout: .now() + 10) == .success { return true }
            pty.closePrimary()
            _ = done.wait(timeout: .now() + 5)
            return false
        }
    }

    /// Runs the prompt on the replica, types `input` once the terminal is
    /// hidden and the prompt shows, and returns the outcome, what the
    /// terminal showed, and whether its mode was put back.
    private func prompt(typing input: String) throws -> (HiddenLinePrompt.Outcome?, String, Bool) {
        let pty = try PTY()
        defer { pty.close() }
        var before = termios()
        #expect(tcgetattr(pty.replica, &before) == 0)
        let reader = Reader()
        reader.start(fd: pty.replica)
        var shown = pty.readOutput(until: "Value for TOKEN: ")
        // Typed before the mode is set, TCSAFLUSH would drop it.
        #expect(pty.waitForHiddenMode())
        pty.write(input)
        #expect(reader.finish(pty), "the prompt never returned")
        shown += pty.readOutput(until: "\n")
        var after = termios()
        #expect(tcgetattr(pty.replica, &after) == 0)
        return (reader.outcome, shown, after.c_lflag == before.c_lflag)
    }

    @Test func readsTheLineWithoutEchoingIt() throws {
        let (outcome, shown, restored) = try prompt(typing: "sk-secret-value\r")
        #expect(outcome == .line(Data("sk-secret-value".utf8)))
        #expect(shown.contains("Value for TOKEN: "))
        #expect(shown.contains("sk-secret") == false)
        #expect(restored)
    }

    @Test func backspaceAndKillEditTheLine() throws {
        let (outcome, _, restored) = try prompt(typing: "wrong\u{15}abcx\u{7F}d\n")
        #expect(outcome == .line(Data("abcd".utf8)))
        #expect(restored)
    }

    @Test func controlCCancelsAndRestoresTheTerminal() throws {
        let (outcome, shown, restored) = try prompt(typing: "half\u{03}")
        #expect(outcome == .cancelled)
        #expect(shown.contains("half") == false)
        #expect(restored)
    }

    @Test func overlongInputIsKeptPastTheLimitSoTheCallerRefusesIt() throws {
        let (outcome, _, _) = try prompt(typing: String(repeating: "a", count: 100) + "\n")
        guard case .line(let data) = outcome else {
            Issue.record("expected a line, got \(outcome)")
            return
        }
        #expect(data.count == 65)
    }

    @Test func aSignalRestoresTheTerminalAndCancels() throws {
        // A SIGTERM handler of the caller's own, so the re-raised signal
        // returns here instead of ending the test run.
        var quiet = sigaction()
        var previous = sigaction()
        #if canImport(Darwin)
        quiet.__sigaction_u.__sa_handler = { _ in }
        #else
        quiet.__sigaction_handler.sa_handler = { _ in }
        #endif
        sigemptyset(&quiet.sa_mask)
        sigaction(SIGTERM, &quiet, &previous)
        defer { sigaction(SIGTERM, &previous, nil) }

        let pty = try PTY()
        defer { pty.close() }
        var before = termios()
        #expect(tcgetattr(pty.replica, &before) == 0)
        let reader = Reader()
        reader.start(fd: pty.replica)
        _ = pty.readOutput(until: "Value for TOKEN: ")
        #expect(pty.waitForHiddenMode())
        pty.write("half")
        if let thread = reader.thread { pthread_kill(thread, SIGTERM) }
        #expect(reader.finish(pty), "the prompt never returned")
        #expect(reader.outcome == .cancelled)
        var after = termios()
        #expect(tcgetattr(pty.replica, &after) == 0)
        #expect(after.c_lflag == before.c_lflag)
    }

    @Test func aPipeIsNotATerminal() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { _ = systemClose(fds[0]); _ = systemClose(fds[1]) }
        #expect(HiddenLinePrompt.read(fd: fds[0], prompt: "x", maximumBytes: 8) == .unavailable)
    }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buffer, count)
    #else
    Glibc.read(fd, buffer, count)
    #endif
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, buffer, count)
    #else
    Glibc.write(fd, buffer, count)
    #endif
}
