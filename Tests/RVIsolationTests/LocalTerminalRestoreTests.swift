import Foundation
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

    @Test func workspaceRunRestoresOnExitCloseDisconnectAndStdinEOF() throws {
        let host = try PTYWorkspaceHost()
        defer { host.close() }
        let endpoint = host.server.endpoint

        try expectRestored(host: host, endpoint: endpoint, onError: { error in
            guard let driveError = error as? WorkspaceTerminalDriveError,
                case .exited(let status) = driveError
            else {
                Issue.record("an exiting runtime must report its status, got \(error)")
                return
            }
            #expect(status == 9)
        }) { client, restorer, pty in
            let runtime = try launchTerminal(client, command: ["/bin/sh", "-c", "printf ready; exit 9"])
            try #require(client.subscribeTerminal(runtime).get() == ())
            try #require(client.acquireTerminalInput(runtime).get() == ())
            try drive(client, runtime: runtime, pty: pty, restorer: restorer)
            Issue.record("an exiting runtime must throw its status")
        }

        try expectRestored(host: host, endpoint: endpoint) { client, restorer, pty in
            let runtime = try launchTerminal(client, command: ["/bin/sh", "-c", "/bin/sleep 30"])
            try #require(client.subscribeTerminal(runtime).get() == ())
            try #require(client.acquireTerminalInput(runtime).get() == ())
            let input = Pipe()
            let thread = Thread {
                try? WorkspaceTerminalDriver.drive(
                    client: client,
                    runtime: runtime,
                    rows: 24,
                    columns: 80,
                    input: input.fileHandleForReading.fileDescriptor,
                    output: FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false),
                    restorer: restorer
                )
            }
            thread.start()
            try input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while thread.isExecuting, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            #expect(thread.isExecuting == false)
            let listed = try WorkspaceClient.connect(endpoint).get()
            #expect(try listed.listRuntimes().get().contains { $0.runtime == runtime && $0.running })
            _ = listed.detach()
        }

        try expectRestored(host: host, endpoint: endpoint) { client, restorer, pty in
            let runtime = try launchTerminal(client, command: ["/bin/sh", "-c", "/bin/sleep 30"])
            try #require(client.subscribeTerminal(runtime).get() == ())
            try #require(client.acquireTerminalInput(runtime).get() == ())
            let closer = try WorkspaceClient.connect(endpoint).get()
            let box = DriveBox()
            let thread = Thread {
                box.finish {
                    try WorkspaceTerminalDriver.drive(
                        client: client,
                        runtime: runtime,
                        rows: 24,
                        columns: 80,
                        input: pty.master,
                        output: FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false),
                        restorer: restorer
                    )
                }
            }
            thread.start()
            #expect(try closer.closeWorkspace().get().phase == .closed)
            let deadline = Date().addingTimeInterval(20)
            while box.error == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let error = try #require(box.error)
            guard let driveError = error as? WorkspaceTerminalDriveError,
                case .client(let failure) = driveError
            else {
                Issue.record("workspace close must fail the driver, got \(error)")
                return
            }
            #expect(failure == .workspaceClosed || failure == .disconnected)
        }
    }

    @Test func disconnectAndProtocolErrorRestoreRawMode() throws {
        let disconnectHost = try PTYWorkspaceHost()
        defer { disconnectHost.close() }
        try expectRestored(host: disconnectHost, endpoint: disconnectHost.server.endpoint) { client, restorer, pty in
            let runtime = try launchTerminal(client, command: ["/bin/sh", "-c", "/bin/sleep 30"])
            try #require(client.subscribeTerminal(runtime).get() == ())
            try #require(client.acquireTerminalInput(runtime).get() == ())
            let box = DriveBox()
            let thread = Thread {
                box.finish {
                    try drive(client, runtime: runtime, pty: pty, restorer: restorer)
                }
            }
            thread.start()
            Thread.sleep(forTimeInterval: 0.2)
            disconnectHost.server.stop()
            let deadline = Date().addingTimeInterval(5)
            while box.error == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let error = try #require(box.error)
            guard let driveError = error as? WorkspaceTerminalDriveError,
                case .client(.disconnected) = driveError
            else {
                Issue.record("disconnect must fail the driver, got \(error)")
                return
            }
            #expect(disconnectHost.supervisor.runtimeFacts().contains { $0.id == runtime && $0.running })
        }

        let protocolHost = try PTYWorkspaceHost()
        defer { protocolHost.close() }
        try expectRestored(host: protocolHost, endpoint: protocolHost.server.endpoint) { client, restorer, pty in
            let runtime = try launchTerminal(client, command: ["/bin/sh", "-c", "/bin/sleep 30"])
            try #require(client.subscribeTerminal(runtime).get() == ())
            try #require(client.acquireTerminalInput(runtime).get() == ())
            let box = DriveBox()
            let thread = Thread {
                box.finish {
                    try drive(client, runtime: runtime, pty: pty, restorer: restorer)
                }
            }
            thread.start()
            Thread.sleep(forTimeInterval: 0.2)
            #expect(protocolHost.server.testingInjectMalformedTerminalFrame())
            let deadline = Date().addingTimeInterval(5)
            while box.error == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let error = try #require(box.error)
            guard let driveError = error as? WorkspaceTerminalDriveError,
                case .client(.malformed) = driveError
            else {
                Issue.record("a bad terminal frame must fail the driver, got \(error)")
                return
            }
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
        local: UInt(term.c_lflag)
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
            sessionStore: .file(runtime)
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
    throw WorkspaceTerminalDriveError.client(.disconnected)
}

private func launchTerminal(_ client: WorkspaceClient, command: [String]) throws -> UUID {
    let report = try client.launchRuntime(
        executable: command[0],
        arguments: Array(command.dropFirst()),
        terminalRows: 24,
        terminalColumns: 80
    ).get()
    #expect(report.terminal)
    return report.runtime
}

private func drive(
    _ client: WorkspaceClient,
    runtime: UUID,
    pty: OpenedPTY,
    restorer: LocalTerminalRestorer?
) throws {
    try WorkspaceTerminalDriver.drive(
        client: client,
        runtime: runtime,
        rows: 24,
        columns: 80,
        input: pty.master,
        output: FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false),
        restorer: restorer
    )
}

private func expectRestored(
    host: PTYWorkspaceHost,
    endpoint: WorkspaceEndpoint,
    onError: ((Error) throws -> Void)? = nil,
    body: (WorkspaceClient, LocalTerminalRestorer, OpenedPTY) throws -> Void
) throws {
    let pty = try OpenedPTY()
    defer { pty.close() }
    let before = try terminalFlags(pty.slave)
    let client = try WorkspaceClient.connect(endpoint).get()
    let restorer = try #require(LocalTerminalRestorer.engage(pty.slave, signals: false))
    do {
        try body(client, restorer, pty)
    } catch {
        try onError?(error)
    }
    #expect(try terminalFlags(pty.slave) == before)
}

private final class DriveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func finish(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            lock.lock()
            stored = error
            lock.unlock()
        }
    }

    var error: Error? {
        lock.lock()
        let value = stored
        lock.unlock()
        return value
    }
}
#endif
