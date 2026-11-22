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
@Suite("Hidden line prompt")
struct HiddenLinePromptTests {
    private struct PTY {
        let primary: Int32
        let replica: Int32

        init() throws {
            var primary: Int32 = -1
            var replica: Int32 = -1
            guard openpty(&primary, &replica, nil, nil, nil) == 0 else { throw POSIXError(.ENODEV) }
            self.primary = primary
            self.replica = replica
        }

        func close() {
            _ = systemClose(primary)
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
            while Date() < deadline {
                var poller = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 100) > 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { systemRead(primary, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                out += buffer.prefix(count)
                if String(decoding: out, as: UTF8.self).contains(marker) { break }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    /// Runs the prompt on the replica in the background, types `input` once
    /// the prompt shows, and returns the outcome and what the terminal showed.
    private func prompt(typing input: String) async throws -> (HiddenLinePrompt.Outcome, String, Bool) {
        let pty = try PTY()
        defer { pty.close() }
        var before = termios()
        #expect(tcgetattr(pty.replica, &before) == 0)
        let replica = pty.replica
        let task = Task.detached {
            HiddenLinePrompt.read(fd: replica, prompt: "Value for TOKEN: ", maximumBytes: 64)
        }
        var shown = pty.readOutput(until: "Value for TOKEN: ")
        pty.write(input)
        let outcome = await task.value
        shown += pty.readOutput(until: "\n")
        var after = termios()
        #expect(tcgetattr(pty.replica, &after) == 0)
        let restored = after.c_lflag == before.c_lflag
        return (outcome, shown, restored)
    }

    @Test func readsTheLineWithoutEchoingIt() async throws {
        let (outcome, shown, restored) = try await prompt(typing: "sk-secret-value\r")
        #expect(outcome == .line(Data("sk-secret-value".utf8)))
        #expect(shown.contains("Value for TOKEN: "))
        #expect(shown.contains("sk-secret") == false)
        #expect(restored)
    }

    @Test func backspaceAndKillEditTheLine() async throws {
        let (outcome, _, restored) = try await prompt(typing: "wrong\u{15}abcx\u{7F}d\n")
        #expect(outcome == .line(Data("abcd".utf8)))
        #expect(restored)
    }

    @Test func controlCCancelsAndRestoresTheTerminal() async throws {
        let (outcome, shown, restored) = try await prompt(typing: "half\u{03}")
        #expect(outcome == .cancelled)
        #expect(shown.contains("half") == false)
        #expect(restored)
    }

    @Test func overlongInputIsKeptPastTheLimitSoTheCallerRefusesIt() async throws {
        let (outcome, _, _) = try await prompt(typing: String(repeating: "a", count: 100) + "\n")
        guard case .line(let data) = outcome else {
            Issue.record("expected a line, got \(outcome)")
            return
        }
        #expect(data.count == 65)
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
