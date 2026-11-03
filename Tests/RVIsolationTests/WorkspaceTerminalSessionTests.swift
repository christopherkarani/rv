#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

@Suite("Workspace terminal session")
struct WorkspaceTerminalSessionTests {
    private static let runtime = UUID()
    private static let foreign = UUID()
    private static let batch = UUID()

    private static func event(
        _ body: WorkspaceTerminalEvent.Body,
        runtime: UUID = runtime
    ) -> Result<WorkspaceTerminalRead, WorkspaceClientFailure> {
        .success(.event(WorkspaceTerminalEvent(runtime: runtime, body: body)))
    }

    struct StepCase: Sendable, CustomTestStringConvertible {
        var name: String
        var read: Result<WorkspaceTerminalRead, WorkspaceClientFailure>
        var expected: WorkspaceTerminalSession.Step
        var testDescription: String { name }
    }

    static let stepCases: [StepCase] = [
        StepCase(name: "wait expired", read: .success(.waiting), expected: .idle),
        StepCase(
            name: "foreign output",
            read: event(.output(sequence: 1, bytes: Data("x".utf8)), runtime: foreign),
            expected: .idle
        ),
        StepCase(name: "foreign exit", read: event(.exited(4), runtime: foreign), expected: .idle),
        StepCase(name: "foreign overflow", read: event(.overflow, runtime: foreign), expected: .idle),
        StepCase(
            name: "replay bytes",
            read: event(.replay(sequence: 1, bytes: Data("old".utf8))),
            expected: .write(Data("old".utf8))
        ),
        StepCase(
            name: "output bytes",
            read: event(.output(sequence: 2, bytes: Data("new".utf8))),
            expected: .write(Data("new".utf8))
        ),
        StepCase(
            name: "replay begin",
            read: event(.replayBegin(batch: batch, truncated: true, byteCount: 3)),
            expected: .idle
        ),
        StepCase(name: "replay end", read: event(.replayEnd(batch: batch)), expected: .idle),
        StepCase(name: "input owner", read: event(.inputOwner(false)), expected: .idle),
        StepCase(name: "window notice", read: event(.window(rows: 30, columns: 100)), expected: .idle),
        StepCase(name: "exit status", read: event(.exited(7)), expected: .exited(7)),
        StepCase(name: "overflow", read: event(.overflow), expected: .failed(.fellBehind)),
        StepCase(name: "workspace closed", read: .failure(.workspaceClosed), expected: .failed(.client(.workspaceClosed))),
        StepCase(name: "disconnect", read: .failure(.disconnected), expected: .failed(.client(.disconnected))),
        StepCase(name: "bad frame", read: .failure(.malformed), expected: .failed(.client(.malformed))),
    ]

    @Test(arguments: stepCases)
    func stepMapsEachTerminalRead(_ row: StepCase) {
        #expect(WorkspaceTerminalSession.step(row.read, runtime: Self.runtime) == row.expected)
    }

    struct InputEndCase: Sendable, CustomTestStringConvertible {
        var ownsInput: Bool
        var abandonOnInputEnd: Bool
        var inputEnded: Bool
        var ends: Bool
        var testDescription: String {
            "owns=\(ownsInput) abandon=\(abandonOnInputEnd) ended=\(inputEnded)"
        }
    }

    /// Only an owned, interactive input that ended abandons the run. A pipe
    /// or /dev/null EOFs at once and must not cut a slow command short.
    static let inputEndCases: [InputEndCase] = [
        InputEndCase(ownsInput: false, abandonOnInputEnd: false, inputEnded: false, ends: false),
        InputEndCase(ownsInput: false, abandonOnInputEnd: false, inputEnded: true, ends: false),
        InputEndCase(ownsInput: false, abandonOnInputEnd: true, inputEnded: false, ends: false),
        InputEndCase(ownsInput: false, abandonOnInputEnd: true, inputEnded: true, ends: false),
        InputEndCase(ownsInput: true, abandonOnInputEnd: false, inputEnded: false, ends: false),
        InputEndCase(ownsInput: true, abandonOnInputEnd: false, inputEnded: true, ends: false),
        InputEndCase(ownsInput: true, abandonOnInputEnd: true, inputEnded: false, ends: false),
        InputEndCase(ownsInput: true, abandonOnInputEnd: true, inputEnded: true, ends: true),
    ]

    @Test(arguments: inputEndCases)
    func endsOnInputOnlyForOwnedInteractiveEOF(_ row: InputEndCase) {
        #expect(
            WorkspaceTerminalSession.endsOnInput(
                ownsInput: row.ownsInput,
                abandonOnInputEnd: row.abandonOnInputEnd,
                inputEnded: row.inputEnded
            ) == row.ends
        )
    }

    /// `stop()` drains through this. A source that never runs dry used to
    /// hold teardown forever; it is not a terminal, so nothing is read.
    @Test func drainSkipsInputThatIsNotATerminal() throws {
        let zero = open("/dev/zero", O_RDONLY)
        try #require(zero >= 0)
        defer { close(zero) }
        #expect(TerminalStdinBridge.drain(zero) == 0)
    }

    @Test func drainDiscardsPendingTerminalInputWithinItsLimit() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer {
            close(master)
            close(slave)
        }
        let line = Array("typed\n".utf8)
        try #require(write(master, line, line.count) == line.count)
        var ready = pollfd(fd: slave, events: Int16(POLLIN), revents: 0)
        try #require(poll(&ready, 1, 1000) == 1)

        #expect(TerminalStdinBridge.drain(slave, limit: 0) == 0)
        #expect(TerminalStdinBridge.drain(slave) == line.count)
        #expect(TerminalStdinBridge.drain(slave) == 0)
    }

    /// A large write to a pipe returns short; the helper keeps going until
    /// every byte is out.
    @Test func writeOutputWritesEveryByteThroughShortWrites() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let readEnd = ends[0]
        let received = Mutex(Data())
        let reader = Thread {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(readEnd, &chunk, chunk.count)
                if count <= 0 { break }
                received.withLock { $0.append(contentsOf: chunk[0..<count]) }
            }
        }
        reader.start()

        let result = WorkspaceTerminalSession.writeOutput(payload, to: ends[1])
        close(ends[1])

        #expect(result == .written)
        let drained = waitUntil(seconds: 5) { received.withLock { $0.count } == payload.count }
        #expect(drained)
        #expect(received.withLock { $0 } == payload)
        close(readEnd)
    }

    /// `rv workspace run -- yes | head -1`: the reader is gone. The write
    /// reports EPIPE instead of raising. The descriptor opts out of SIGPIPE
    /// here so this test leaves the process-wide disposition alone.
    @Test func writeOutputReportsAClosedPipeInsteadOfRaising() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        defer { close(ends[1]) }
        close(ends[0])
        try #require(fcntl(ends[1], F_SETNOSIGPIPE, 1) == 0)

        #expect(
            WorkspaceTerminalSession.writeOutput(Data("y\n".utf8), to: ends[1]) == .failed(errno: EPIPE)
        )
    }

    @Test func writeOutputReportsOtherWriteErrors() {
        #expect(WorkspaceTerminalSession.writeOutput(Data("y".utf8), to: -1) == .failed(errno: EBADF))
    }

    @Test func writeOutputOfNothingSucceeds() {
        #expect(WorkspaceTerminalSession.writeOutput(Data(), to: -1) == .written)
    }

    /// Inherited O_NONBLOCK on stdout makes a full pipe or terminal return
    /// EAGAIN. That is back-pressure, not a closed reader: the helper waits
    /// for room and finishes the write.
    @Test func writeOutputWaitsOutANonBlockingFullPipe() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        try #require(fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK) == 0)
        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let readEnd = ends[0]
        let received = Mutex(Data())
        let reader = Thread {
            var chunk = [UInt8](repeating: 0, count: 4 * 1024)
            while true {
                let count = read(readEnd, &chunk, chunk.count)
                if count <= 0 { break }
                received.withLock { $0.append(contentsOf: chunk[0..<count]) }
                usleep(100)
            }
        }
        reader.start()

        let result = WorkspaceTerminalSession.writeOutput(payload, to: ends[1])
        close(ends[1])

        #expect(result == .written)
        let drained = waitUntil(seconds: 10) { received.withLock { $0.count } == payload.count }
        #expect(drained)
        #expect(received.withLock { $0 } == payload)
        close(readEnd)
    }

    /// What the session does: while SIGPIPE is ignored, a closed pipe is an
    /// EPIPE the process survives. The disposition is process-wide, so this
    /// is the only test in this bundle that changes it. It installs its own
    /// SA_SIGINFO handler first, so the check does not depend on what the
    /// runner inherited, and puts the inherited action back at the end.
    /// Overlapping holders keep SIGPIPE ignored until the last restore puts
    /// back the whole action the first saved; an unmatched restore is inert.
    @Test func brokenPipeIgnoreIsScopedAndRestoresThePriorDisposition() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        defer { close(ends[1]) }
        close(ends[0])
        var inherited = sigaction()
        try #require(sigaction(SIGPIPE, nil, &inherited) == 0)
        defer { sigaction(SIGPIPE, &inherited, nil) }
        var installed = sigaction()
        installed.__sigaction_u.__sa_sigaction = { _, _, _ in }
        sigemptyset(&installed.sa_mask)
        sigaddset(&installed.sa_mask, SIGUSR2)
        installed.sa_flags = SA_SIGINFO | SA_RESTART
        try #require(sigaction(SIGPIPE, &installed, nil) == 0)
        let before = Self.pipeAction()

        WorkspaceTerminalSession.BrokenPipe.restore()
        #expect(Self.pipeAction() == before)

        WorkspaceTerminalSession.BrokenPipe.ignore()
        #expect(Self.pipeAction().handler == Self.ignoredHandler)
        #expect(
            WorkspaceTerminalSession.writeOutput(Data("y\n".utf8), to: ends[1]) == .failed(errno: EPIPE)
        )
        WorkspaceTerminalSession.BrokenPipe.ignore()
        WorkspaceTerminalSession.BrokenPipe.restore()
        #expect(Self.pipeAction().handler == Self.ignoredHandler)
        WorkspaceTerminalSession.BrokenPipe.restore()

        #expect(Self.pipeAction() == before)
        #expect(before.handler != Self.ignoredHandler)
        #expect(before.flags == SA_SIGINFO | SA_RESTART)
    }

    private struct PipeAction: Equatable {
        var handler: Int
        var mask: sigset_t
        var flags: Int32
    }

    private static let ignoredHandler = unsafeBitCast(SIG_IGN, to: Int.self)

    private static func pipeAction() -> PipeAction {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        return PipeAction(
            handler: unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self),
            mask: current.sa_mask,
            flags: current.sa_flags
        )
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}
#endif
