import Foundation
import Synchronization
import Testing
#if os(macOS)
import Darwin
import RVDomain
@testable import RVIsolation

@Suite("Local terminal restore", .serialized)
struct LocalTerminalRestoreTests {
    @Test func engageAndRestoreAreIdempotent() throws {
        let pty = try OpenedPTY()
        defer { pty.close() }
        let before = try terminalFlags(pty.slave)
        let restorer = try #require(LocalTerminalRestorer.engage(pty.slave, signals: true))
        let raw = try terminalFlags(pty.slave)
        #expect(raw.local & UInt(ICANON) == 0)
        #expect(raw.local & UInt(ECHO) == 0)
        #expect(raw.local & UInt(ISIG) != 0)
        restorer.restoreInstalledSignal()
        let signaled = try terminalFlags(pty.slave)
        #expect(signaled == before)
        restorer.restore()
        restorer.restore()
        #expect(try terminalFlags(pty.slave) == before)

        let quiet = try OpenedPTY()
        defer { quiet.close() }
        let quietBefore = try terminalFlags(quiet.slave)
        let withoutSignals = try #require(LocalTerminalRestorer.engage(quiet.slave, signals: false))
        let quietRaw = try terminalFlags(quiet.slave)
        #expect(quietRaw.local & UInt(ISIG) == 0)
        #expect(quietRaw.local & UInt(ICANON) == 0)
        withoutSignals.restore()
        #expect(try terminalFlags(quiet.slave) == quietBefore)
    }

    @Test func secondEngageDoesNotReplaceTheArmedSavedMode() throws {
        let first = try OpenedPTY()
        defer { first.close() }
        let before = try terminalFlags(first.slave)
        let restorer = try #require(LocalTerminalRestorer.engage(first.slave, signals: true))
        let second = try OpenedPTY()
        defer { second.close() }
        let secondBefore = try terminalFlags(second.slave)
        #expect(LocalTerminalRestorer.engage(second.slave, signals: true) == nil)
        #expect(try terminalFlags(second.slave) == secondBefore)
        restorer.restore()
        #expect(try terminalFlags(first.slave) == before)
    }

    @Test(.enabled(if: peerTrustCI, "TRANSITIONAL-PEER-AUTH: code-identity roles reject test binaries and scoped operator permits deny launch/terminal ops; re-enable when test trust + permits land")) func workspaceRunRestoresOnExitCloseDisconnectAndStdinEOF() throws {
        let host = try PTYWorkspaceHost()
        defer { host.close() }
        let endpoint = host.server.endpoint

        try expectRestored(endpoint: endpoint) { client, pty in
            // A fast exit can win the race with acquire. The status is still
            // on the stream, and the session still has to put the terminal back.
            let box = SessionBox()
            box.run(client, command: ["/bin/sh", "-c", "printf ready; exit 9"], pty: pty, input: pty.master)
            #expect(box.result == .success(.exited(9)))
        }

        try expectRestored(endpoint: endpoint) { client, pty in
            let input = Pipe()
            try input.fileHandleForWriting.close()
            let box = SessionBox()
            box.run(
                client, command: ["/bin/sh", "-c", "/bin/sleep 30"], pty: pty,
                input: input.fileHandleForReading.fileDescriptor, abandonOnInputEnd: true
            )
            #expect(box.isEngaged)
            #expect(box.result == .success(.inputEnded))
            let runtime = try #require(box.runtime)
            let listed = try WorkspaceClient.connect(endpoint).get()
            #expect(try listed.listRuntimes().get().contains { $0.runtime == runtime && $0.running })
            _ = listed.detach()
        }

        try expectRestored(endpoint: endpoint) { client, pty in
            // Without abandonOnInputEnd a pipe EOF keeps waiting for the exit.
            let input = Pipe()
            try input.fileHandleForWriting.close()
            let box = SessionBox()
            box.run(
                client, command: ["/bin/sh", "-c", "/bin/sleep 0.5; exit 3"], pty: pty,
                input: input.fileHandleForReading.fileDescriptor, abandonOnInputEnd: false
            )
            #expect(box.result == .success(.exited(3)))
        }

        try expectRestored(endpoint: endpoint) { client, pty in
            let closer = try WorkspaceClient.connect(endpoint).get()
            let box = SessionBox()
            box.start(client, command: ["/bin/sh", "-c", "/bin/sleep 30"], pty: pty, input: pty.master)
            try #require(waitUntil(seconds: 10) { box.isEngaged })
            #expect(try closer.closeWorkspace().get().phase == .closed)
            let result = try #require(waitFor(seconds: 20) { box.result })
            // Close kills the child, so its signal status can reach the
            // session before `workspaceClosed`. Either ends the session.
            switch result {
            case .failure(.client(.workspaceClosed)), .failure(.client(.disconnected)), .success(.exited):
                break
            default:
                Issue.record("workspace close must end the session, got \(result)")
            }
        }
    }

    @Test(.enabled(if: peerTrustCI, "TRANSITIONAL-PEER-AUTH: code-identity roles reject test binaries and scoped operator permits deny launch/terminal ops; re-enable when test trust + permits land")) func disconnectAndProtocolErrorRestoreRawMode() throws {
        let disconnectHost = try PTYWorkspaceHost()
        defer { disconnectHost.close() }
        try expectRestored(endpoint: disconnectHost.server.endpoint) { client, pty in
            let box = SessionBox()
            box.start(client, command: ["/bin/sh", "-c", "/bin/sleep 30"], pty: pty, input: pty.master)
            try #require(waitUntil(seconds: 10) { box.isEngaged })
            Thread.sleep(forTimeInterval: 0.2)
            disconnectHost.server.stop()
            let result = try #require(waitFor(seconds: 5) { box.result })
            #expect(result == .failure(.client(.disconnected)))
            let runtime = try #require(box.runtime)
            #expect(disconnectHost.supervisor.runtimeFacts().contains { $0.id == runtime && $0.running })
        }

        let protocolHost = try PTYWorkspaceHost()
        defer { protocolHost.close() }
        try expectRestored(endpoint: protocolHost.server.endpoint) { client, pty in
            let box = SessionBox()
            box.start(client, command: ["/bin/sh", "-c", "/bin/sleep 30"], pty: pty, input: pty.master)
            try #require(waitUntil(seconds: 10) { box.isEngaged })
            Thread.sleep(forTimeInterval: 0.2)
            #expect(protocolHost.server.testingInjectMalformedTerminalFrame())
            let result = try #require(waitFor(seconds: 5) { box.result })
            #expect(result == .failure(.client(.malformed)))
            let runtime = try #require(box.runtime)
            let again = try WorkspaceClient.connect(protocolHost.server.endpoint).get()
            #expect(try again.listRuntimes().get().contains { $0.runtime == runtime && $0.running })
            _ = again.detach()
        }
    }

    @Test func clientInterruptRestoresTheLocalTerminal() throws {
        let probe = try builtProbe()
        let pty = try OpenedPTY()
        defer { pty.close() }
        let before = try terminalFlags(pty.slave)
        let process = Process()
        process.executableURL = probe
        process.standardInput = FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false)
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 1)
        if process.terminationStatus != 1 {
            Issue.record("probe status \(process.terminationStatus) stderr \(stderr)")
        }
        #expect(try terminalFlags(pty.slave) == before)
    }
}

private struct TerminalFlags: Equatable {
    var input: UInt
    var output: UInt
    var local: UInt
}

private func terminalFlags(_ fd: Int32) throws -> TerminalFlags {
    var term = termios()
    try #require(tcgetattr(fd, &term) == 0)
    return TerminalFlags(
        input: UInt(term.c_iflag),
        output: UInt(term.c_oflag),
        local: UInt(term.c_lflag) & ~0x2000_0000
    )
}

private struct OpenedPTY {
    var master: Int32
    var slave: Int32

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        self.master = master
        self.slave = slave
    }

    func close() {
        Darwin.close(master)
        Darwin.close(slave)
    }
}

private struct PTYWorkspaceHost {
    var root: URL
    var supervisor: WorkspaceSessionSupervisor
    var server: WorkspaceHostServer

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-local-term-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let life = config.appendingPathComponent("life.jsonl")
        let runtime = config.appendingPathComponent("runtime.jsonl")
        let directory = try #require(WorkingDirectory(validating: workspace.path))
        supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(life),
            runtimeLog: runtime
        ).get()
        server = try WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: config,
            sessionStore: .file(runtime),
            admission: .failClosed
        ).get()
    }

    func close() {
        server.stop()
        _ = supervisor.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func builtProbe() throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var candidates = [
        root.appendingPathComponent(".build/out/Products/Debug/rv-terminal-probe"),
        root.appendingPathComponent(".build/debug/rv-terminal-probe"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/rv-terminal-probe"),
    ]
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent("rv-terminal-probe"))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        return found
    }
    Issue.record("missing built product rv-terminal-probe")
    throw MissingProbe()
}

private struct MissingProbe: Error {}

/// Runs one `WorkspaceTerminalSession` against a host. Raw mode goes on the
/// PTY slave, which is also the output, so `expectRestored` can check it.
private final class SessionBox: Sendable {
    private let state = Mutex<State>(State())

    private struct State {
        var runtime: UUID?
        var engaged = false
        var result: Result<WorkspaceTerminalOutcome, WorkspaceTerminalSessionFailure>?
    }

    func run(
        _ client: WorkspaceClient,
        command: [String],
        pty: OpenedPTY,
        input: Int32,
        abandonOnInputEnd: Bool = false
    ) {
        let result = Result { () throws(WorkspaceTerminalSessionFailure) -> WorkspaceTerminalOutcome in
            try WorkspaceTerminalSession.run(
                client: client,
                launch: { client in
                    let launched = client.launchRuntime(
                        executable: command[0],
                        arguments: Array(command.dropFirst()),
                        terminalRows: 24,
                        terminalColumns: 80
                    )
                    if case .success(let report) = launched {
                        self.state.withLock { $0.runtime = report.runtime }
                    }
                    return launched
                },
                rows: 24,
                columns: 80,
                abandonOnInputEnd: abandonOnInputEnd,
                input: input,
                output: pty.slave,
                rawMode: { _ in
                    let restorer = LocalTerminalRestorer.engage(pty.slave, signals: false)
                    self.state.withLock { $0.engaged = restorer != nil }
                    return restorer
                }
            )
        }
        state.withLock { $0.result = result }
    }

    func start(_ client: WorkspaceClient, command: [String], pty: OpenedPTY, input: Int32) {
        let thread = Thread {
            self.run(client, command: command, pty: pty, input: input)
        }
        thread.start()
    }

    var runtime: UUID? { state.withLock { $0.runtime } }
    var isEngaged: Bool { state.withLock { $0.engaged } }
    var result: Result<WorkspaceTerminalOutcome, WorkspaceTerminalSessionFailure>? {
        state.withLock { $0.result }
    }
}

private func waitFor<T>(seconds: TimeInterval, _ value: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let found = value() { return found }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return value()
}

private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    waitFor(seconds: seconds) { condition() ? true : nil } ?? false
}

/// Checks the PTY slave's mode is back after `body`, and that the session
/// detached its client.
private func expectRestored(
    endpoint: WorkspaceEndpoint,
    body: (WorkspaceClient, OpenedPTY) throws -> Void
) throws {
    let pty = try OpenedPTY()
    defer { pty.close() }
    let before = try terminalFlags(pty.slave)
    let client = try WorkspaceClient.connect(endpoint).get()
    try body(client, pty)
    #expect(try terminalFlags(pty.slave) == before)
    if case .success = client.ping() {
        Issue.record("the session must detach its client")
    }
}
#endif
