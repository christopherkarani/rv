import Darwin
import Foundation
import RVMacVMAgent
import RVMicroVMCore
import Testing

/// The built `rv-macvm-agent`, used as the exec trampoline exactly as in a guest.
/// Found beside this test bundle (`<products>/X.xctest/Contents/MacOS/X`).
private let agentBinary: String = {
    var info = Dl_info()
    let marker: @convention(c) () -> Void = {}
    precondition(dladdr(unsafeBitCast(marker, to: UnsafeRawPointer.self), &info) != 0)
    var url = URL(fileURLWithPath: String(cString: info.dli_fname))
    while url.pathExtension != "xctest", url.path != "/" { url.deleteLastPathComponent() }
    return url.deletingLastPathComponent().appendingPathComponent(MacVMAgent.executableName).path
}()

/// The same control rules rv's host cage applies (SeatbeltProfile.workspaceControlDenies).
private func profile(_ workspace: String) -> String {
    """
    (version 1)
    (allow default)
    (deny file-write* (subpath "\(workspace)/.git/hooks") (subpath "\(workspace)/.rv")
        (subpath "\(workspace)/.config/rv") (literal "\(workspace)/.git/config"))
    (deny file-write-data file-write-unlink file-write-create (literal "\(workspace)/.git"))
    (deny file-write-unlink file-write-create (literal "\(workspace)/.config"))
    """
}

private final class Workspace {
    let path: String
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // realpath, not resolvingSymlinksInPath (which strips /private):
        // Seatbelt matches the real path.
        guard let real = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        path = String(cString: real)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// One agent session on a socketpair; the test drives the host end.
private final class Harness {
    let host: MacVMChannel
    private let finished = DispatchSemaphore(value: 0)
    private(set) var frames: [MacVMFrame] = []

    init(relays: [Int: Int] = [:]) {
        var pair: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        host = MacVMChannel(descriptor: pair[0])
        let agent = MacVMChannel(descriptor: pair[1])
        let configuration = AgentConfiguration(
            trampoline: agentBinary,
            user: nil,
            mountWorkspace: { _ in nil },
            connectRelay: { port in relays[port].flatMap { connectLoopback(port: $0) } }
        )
        let done = finished
        Thread.detachNewThread {
            AgentSession.serve(agent, configuration: configuration)
            close(pair[1])
            done.signal()
        }
    }

    func exec(_ workspace: String, _ arguments: [String], terminal: Bool = true, relayPorts: [Int] = []) {
        host.send(.exec(MacVMExecRequest(
            workspace: workspace, arguments: arguments, environment: ["PATH=/usr/bin:/bin", "MARK=guest"],
            terminal: terminal, rows: 30, columns: 100, relayPorts: relayPorts, sandboxProfile: profile(workspace)
        )))
    }

    /// Frames until `exit`/`failure` or end of stream.
    @discardableResult
    func collect(until stop: (MacVMFrame) -> Bool = { _ in false }) throws -> [MacVMFrame] {
        while let frame = try host.receive() {
            frames.append(frame)
            if stop(frame) { break }
            if case .exit = frame { break }
            if case .failure = frame { break }
        }
        return frames
    }

    var output: String {
        frames.reduce(into: "") { text, frame in
            if case .output(let data) = frame { text += String(decoding: data, as: UTF8.self) }
        }
    }
    var errorOutput: String {
        frames.reduce(into: "") { text, frame in
            if case .errorOutput(let data) = frame { text += String(decoding: data, as: UTF8.self) }
        }
    }
    var exit: Int32? {
        frames.lazy.compactMap { if case .exit(let status) = $0 { status } else { nil } }.first
    }

    func waitFinished() -> Bool { finished.wait(timeout: .now() + 10) == .success }
}

@Suite("macOS guest agent session", .serialized)
struct AgentSessionTests {
    @Test("a terminal command runs in the workspace with the request's size, environment and exit status")
    func terminalCommand() throws {
        let ws = try Workspace()
        let harness = Harness()
        harness.exec(ws.path, ["/bin/sh", "-c", "echo hi; pwd; stty size; echo $MARK; exit 3"])
        try harness.collect()
        #expect(harness.frames.first == .started)
        #expect(harness.output.contains("hi"))
        #expect(harness.output.contains(ws.path))
        #expect(harness.output.contains("30 100"))
        #expect(harness.output.contains("guest"))
        #expect(harness.exit == 3)
        #expect(harness.waitFinished())
    }

    /// A host that reads slowly must still get every byte, and all of it
    /// before `exit`: the agent waits for its output pumps, not a timer.
    @Test("all output arrives before exit even when the host reads slowly", arguments: [true, false])
    func slowHostGetsAllOutput(terminal: Bool) throws {
        let ws = try Workspace()
        let harness = Harness()
        // Small enough that the command exits at once with output still
        // buffered in the pipe, large enough to fill the socket.
        let bytes = 60_000
        harness.exec(ws.path, ["/bin/sh", "-c", "/usr/bin/yes abcdefg | /usr/bin/head -c \(bytes)"], terminal: terminal)
        Thread.sleep(forTimeInterval: 2)
        try harness.collect()
        let stream = harness.frames.reduce(into: Data()) { all, frame in
            if case .output(let data) = frame { all.append(data) }
        }
        // A terminal translates LF to CRLF, and macOS repeats the CR when its
        // output queue fills between the two, so compare without CRs.
        let text = terminal ? stream.filter { $0 != 13 } : stream
        let expected = Data(String(repeating: "abcdefg\n", count: bytes / 8).utf8)
        #expect(text == expected, "\(stream.count) bytes, \(text.count) without CRs")
        #expect(harness.exit == 0)
        #expect(harness.waitFinished())
    }

    @Test("without a terminal, stdin, stdout and stderr are separate streams")
    func pipes() throws {
        let ws = try Workspace()
        let harness = Harness()
        harness.exec(ws.path, ["/bin/sh", "-c", "cat; echo err >&2"], terminal: false)
        harness.host.send(.input(Data("abc".utf8)))
        harness.host.send(.input(Data()))
        try harness.collect()
        #expect(harness.output == "abc")
        #expect(harness.errorOutput == "err\n")
        #expect(harness.exit == 0)
    }

    @Test("the guest sandbox denies workspace control paths and allows normal writes")
    func sandbox() throws {
        let ws = try Workspace()
        try FileManager.default.createDirectory(atPath: ws.path + "/.rv", withIntermediateDirectories: true)
        let harness = Harness()
        harness.exec(ws.path, ["/bin/sh", "-c", """
            if echo x > .rv/policy.toml 2>/dev/null; then echo rv=allowed; else echo rv=denied; fi
            if mkdir .git 2>/dev/null; then echo git=allowed; else echo git=denied; fi
            echo ok > notes.txt
            """])
        try harness.collect()
        #expect(harness.output.contains("rv=denied"), "\(harness.output)")
        #expect(harness.output.contains("git=denied"), "\(harness.output)")
        #expect(FileManager.default.fileExists(atPath: ws.path + "/notes.txt"))
        #expect(FileManager.default.fileExists(atPath: ws.path + "/.rv/policy.toml") == false)
    }

    @Test("a signal from the host reaches the command")
    func signal() throws {
        let ws = try Workspace()
        let harness = Harness()
        harness.exec(ws.path, ["/bin/sh", "-c", "trap 'echo term; exit 9' TERM; echo ready; while :; do sleep 0.1; done"])
        try harness.collect { _ in harness.output.contains("ready") }
        harness.host.send(.signal(SIGTERM))
        try harness.collect()
        #expect(harness.output.contains("term"))
        #expect(harness.exit == 9)
    }

    @Test("a terminal Ctrl-C and a host SIGINT end the command with the shell's 130", arguments: [true, false])
    func interrupt(fromTerminal: Bool) throws {
        let ws = try Workspace()
        let harness = Harness()
        harness.exec(ws.path, ["/bin/sh", "-c", "echo ready; exec /bin/sleep 30"])
        try harness.collect { _ in harness.output.contains("ready") }
        harness.host.send(fromTerminal ? .input(Data([0x03])) : .signal(SIGINT))
        try harness.collect()
        #expect(harness.exit == 130)
    }

    @Test("background processes the command leaves behind are killed when it exits")
    func leftovers() throws {
        let ws = try Workspace()
        let harness = Harness()
        let marker = "32.\(Int.random(in: 1000...9999))"
        let started = Date()
        harness.exec(ws.path, ["/bin/sh", "-c", "/bin/sleep \(marker) >/dev/null 2>&1 & echo started-bg; exit 4"])
        try harness.collect()
        #expect(harness.exit == 4)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(isRunning(marker) == false)
    }

    /// sshd sessions run outside the command's sandbox, so the command
    /// must not reach sshd on loopback, whatever its profile allows.
    @Test("the command cannot connect to loopback port 22")
    func noLoopbackSSH() throws {
        let ws = try Workspace()
        let harness = Harness()
        harness.exec(ws.path, ["/bin/sh", "-c", "/usr/bin/nc -vz -G 2 127.0.0.1 22 2>&1; echo status=$?"])
        try harness.collect()
        #expect(harness.output.contains("Operation not permitted"), "\(harness.output)")
        #expect(harness.output.contains("status=1"))
    }

    @Test("a relayed guest loopback port reaches the host service")
    func relay() throws {
        let ws = try Workspace()
        let echo = try EchoServer()
        let guestPort = try freePort()
        let harness = Harness(relays: [guestPort: echo.port])
        harness.exec(
            ws.path,
            ["/bin/bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/\(guestPort); echo ping >&3; read -r line <&3; echo \"got $line\""],
            relayPorts: [guestPort]
        )
        try harness.collect()
        #expect(harness.output.contains("got ping"), "\(harness.output)")
        #expect(harness.exit == 0)
    }

    @Test("requests the agent must refuse get a failure frame and nothing runs")
    func refusals() throws {
        let ws = try Workspace()
        let relative = Harness()
        relative.exec(ws.path, ["sh", "-c", "touch \(ws.path)/ran"])
        try relative.collect()
        guard case .failure = relative.frames.last else {
            Issue.record("relative executable must fail: \(relative.frames)")
            return
        }
        let notExec = Harness()
        notExec.host.send(.input(Data("x".utf8)))
        try notExec.collect()
        guard case .failure = notExec.frames.last else {
            Issue.record("a session must start with exec: \(notExec.frames)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: ws.path + "/ran") == false)
    }

    @Test("losing the host connection kills the command's process group")
    func hostGone() throws {
        let ws = try Workspace()
        let harness = Harness()
        let marker = "31.\(Int.random(in: 1000...9999))"
        harness.exec(ws.path, ["/bin/sh", "-c", "/bin/sleep \(marker) & echo started-bg; wait"])
        try harness.collect { _ in harness.output.contains("started-bg") }
        #expect(isRunning(marker))
        harness.host.shutdown()
        #expect(harness.waitFinished())
        let deadline = Date().addingTimeInterval(5)
        while isRunning(marker), Date() < deadline { usleep(50_000) }
        #expect(isRunning(marker) == false)
    }
}

private func isRunning(_ marker: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "sleep \(marker)"]
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return Int(UInt16(bigEndian: address.sin_port))
}

/// Loopback TCP echo server on an ephemeral port.
private final class EchoServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 8)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        fd = listener
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = read(client, &buffer, buffer.count)
                        if count <= 0 { break }
                        _ = write(client, buffer, count)
                    }
                    close(client)
                }
            }
        }
    }

    deinit { close(fd) }
}
