#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVMCP

private struct ListenerFailed: Error {}

/// A `network: false` cage (every placeholder-bearing server) and other
/// processes outside it: a Unix-domain socket the test itself listens on, and
/// a live neighbour's open files and resource counters. Only the test's own
/// listener and its own probe process are touched, all under the resolved
/// temp directory.
extension MCPCageCredentialLiveTests {
    /// `(deny network*)` refuses an AF_UNIX stream connect and a datagram
    /// `connect` and `sendto`, as well as TCP and UDP: on its own, and with
    /// the loopback allow every placeholder server gets on top of it (port 9
    /// is only named in the profile, never dialled). The sockets are in the
    /// cage's own temporary write root, so file permissions are not what
    /// stops them. An uncaged probe reaches the same listeners before and
    /// after the caged one, so the refusal cannot come from a dead listener;
    /// the caged attempts are made once. Worst case about 82 s of bounded
    /// waits, inside the limit.
    @Test(.timeLimit(.minutes(2)), arguments: [[], [9]] as [[Int]])
    func aNetworkFalseCageCannotConnectToAUnixSocket(loopbackPorts: [Int]) throws {
        let probe = try mcpProbe()
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-ux-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/unix", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let streamPath = tmp.appendingPathComponent("s").path
        let datagramPath = tmp.appendingPathComponent("d").path
        let stream = try Self.unixListener(at: streamPath, type: SOCK_STREAM)
        defer { close(stream) }
        let datagram = try Self.unixListener(at: datagramPath, type: SOCK_DGRAM)
        defer { close(datagram) }
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path,
            loopbackPorts: loopbackPorts).get()
        #expect(profile.contains("(deny network*)"))
        for port in loopbackPorts {
            #expect(profile.contains("(allow network-outbound (remote tcp \"localhost:\(port)\"))"))
        }

        func controlReaches() throws {
            let connected = Self.fromHere(probe, ["unix-connect", streamPath], in: root)
            try #require(connected.contains("unix-connect connected sent=1"), "uncaged stream control: \(connected)")
            try #require(Self.pending(stream, within: 5) == Array("x".utf8), "the stream listener did not get the control byte")
            let sent = Self.fromHere(probe, ["unix-dgram", datagramPath], in: root)
            try #require(sent.contains("dgram-connect ok dgram-sendto sent=1"), "uncaged datagram control: \(sent)")
            try #require(Self.datagram(datagram, within: 5) == Array("y".utf8), "the datagram listener did not get the control byte")
        }
        try controlReaches()

        let output = try #require(try caged(
            profile, "\"$1\" unix-connect \"$2\"; \"$1\" unix-dgram \"$3\"; echo DONE",
            [probe.path, streamPath, datagramPath], in: scratch.path))
        #expect(output.contains("DONE"), "\(output)")
        // Each answer is matched with the delimiter the probe prints after
        // it, so only errno 1 passes, not 10-19.
        #expect(output.contains("unix-connect failed errno=\(EPERM)\n"), "\(output)")
        #expect(output.contains("dgram-connect failed errno=\(EPERM) "), "\(output)")
        #expect(output.contains("dgram-sendto failed errno=\(EPERM)\n"), "\(output)")
        #expect(output.contains("connected") == false, "\(output)")
        #expect(output.contains(" ok") == false, "\(output)")
        #expect(output.contains("sent=1") == false, "\(output)")
        #expect(Self.pending(stream, within: 1) == nil, "a caged connection reached the stream listener")
        #expect(Self.datagram(datagram, within: 1) == nil, "a caged datagram reached the listener")

        try controlReaches()
    }

    /// `proc_pidfdinfo` (of the neighbour's stdin, a pipe) and
    /// `proc_pid_rusage` of a live process outside the cage are refused. The
    /// neighbour is shown readable from here before and after, and still
    /// running; the caged read is made once. Worst case about 60 s of
    /// bounded waits (two 20 s controls and the 20 s caged run), inside the
    /// limit, so a starved run fails on a message rather than the limit.
    @Test(.timeLimit(.minutes(2)))
    func aCagedServerCannotReadAPeersFileOrResourceInfo() throws {
        let probe = try mcpProbe()
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-peerinfo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/peer", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()

        let neighbour = Process()
        neighbour.executableURL = probe
        neighbour.arguments = ["hold"]
        let input = Pipe()
        neighbour.standardInput = input
        neighbour.standardOutput = FileHandle.nullDevice
        neighbour.standardError = FileHandle.nullDevice
        try neighbour.run()
        defer {
            try? input.fileHandleForWriting.close()
            if neighbour.isRunning { kill(neighbour.processIdentifier, SIGKILL) }
            neighbour.waitUntilExit()
        }
        let pid = String(neighbour.processIdentifier)
        func readable(_ answer: String) -> Bool { answer.contains("pidfdinfo ok") && answer.contains("rusage ok") }
        let before = Self.fromHere(probe, ["peerinfo", pid], in: root, until: readable, within: 10)
        try #require(readable(before), "the neighbour was never readable here: \(before)")

        let output = try #require(try caged(profile, "\"$1\" peerinfo \"$2\"; echo DONE", [probe.path, pid], in: scratch.path))
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains("pidfdinfo failed errno=\(EPERM) "), "\(output)")
        #expect(output.contains("rusage failed errno=\(EPERM)\n"), "\(output)")

        let after = Self.fromHere(probe, ["peerinfo", pid], in: root, until: readable, within: 10)
        #expect(readable(after), "\(after)")
        #expect(neighbour.isRunning)
    }

    /// A non-blocking AF_UNIX socket of `type` bound at `path`, listening
    /// when it is a stream socket.
    static func unixListener(at path: String, type: Int32) throws -> Int32 {
        try #require(path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path), "socket path too long: \(path)")
        let fd = socket(AF_UNIX, type, 0)
        try #require(fd >= 0, "socket: errno \(errno)")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, type != SOCK_STREAM || listen(fd, 8) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let failure = errno
            close(fd)
            Issue.record("listener at \(path): errno \(failure)")
            throw ListenerFailed()
        }
        return fd
    }

    /// The bytes of one connection waiting on `listener` within `seconds`,
    /// or nil when none arrived.
    static func pending(_ listener: Int32, within seconds: Int32) -> [UInt8]? {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, seconds * 1000) == 1 else { return nil }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return nil }
        defer { close(connection) }
        var readable = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
        _ = poll(&readable, 1, 2000)
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(connection, &buffer, buffer.count)
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    /// The bytes of one datagram waiting on `socket` within `seconds`, or nil
    /// when none arrived.
    static func datagram(_ socket: Int32, within seconds: Int32) -> [UInt8]? {
        var ready = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, seconds * 1000) == 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = recv(socket, &buffer, buffer.count, 0)
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    /// `rv-mcp-probe <arguments>` run uncaged, retried every 50 ms until
    /// `until` holds or `within` seconds pass. Only for positive controls.
    static func fromHere(
        _ probe: URL, _ arguments: [String], in directory: URL, until: (String) -> Bool, within seconds: TimeInterval
    ) -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var answer = fromHere(probe, arguments, in: directory)
        while until(answer) == false, Date() < deadline {
            usleep(50_000)
            answer = fromHere(probe, arguments, in: directory)
        }
        return answer
    }

    /// `rv-mcp-probe <arguments>` run uncaged, its answer written to a file in
    /// `directory`; empty when it did not finish in 10 s.
    static func fromHere(_ probe: URL, _ arguments: [String], in directory: URL) -> String {
        let output = directory.appendingPathComponent("from-here-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: output)
        else { return "" }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = probe
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            return ""
        }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }
}
#endif
