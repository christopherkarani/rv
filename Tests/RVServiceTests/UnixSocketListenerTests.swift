#if canImport(Darwin)
import Darwin
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

@Suite(.serialized)
struct UnixSocketListenerTests {
    @Test func listenerOnIsolatedHomeDeniesResetHardAndModesAreOwnerOnly() async throws {
        let home = try makeIsolatedHome("listener")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let runtime = try isolatedRuntime()
        let listener = UnixSocketListener(
            runtime: runtime,
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        defer { listener.stop() }

        #expect(try UnixSocketPath.posixMode(of: socketURL.deletingLastPathComponent()) & 0o777 == 0o700)
        #expect(
            try UnixSocketPath.posixMode(of: socketURL.deletingLastPathComponent().deletingLastPathComponent())
                & 0o777 == 0o700
        )
        #expect(try UnixSocketPath.posixMode(of: socketURL) & 0o777 == 0o600)

        let client = try retryDarwinConnect(path: socketURL.path)
        defer { client.close() }
        let ack = try IPCJSON.decode(HelloAck.self, from: client.send(body: try IPCJSON.encode(Hello())))
        #expect(ack.status == .ok)

        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: client.send(body: try IPCJSON.encode(darwinResetHardRequest()))
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("socket evaluate must return evaluate")
            return
        }
        #expect(reply.via == .service)
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("socket evaluate must deny reset-hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func methodBeforeHelloIsHandshakeRequired() throws {
        let home = try makeIsolatedHome("unready")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let listener = UnixSocketListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        defer { listener.stop() }

        let client = try retryDarwinConnect(path: socketURL.path)
        defer { client.close() }
        let request = IPCRequest(method: .listPacks)
        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: client.send(body: try IPCJSON.encode(request))
        )
        guard case .error(.protocolSkew(.handshakeRequired)) = response.result else {
            Issue.record("pre-hello listPacks must be handshakeRequired, got \(response.result)")
            return
        }
        #expect(response.id == request.id)
    }

    @Test func skewedHelloIsRejected() throws {
        let home = try makeIsolatedHome("skew")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let listener = UnixSocketListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        defer { listener.stop() }

        let client = try retryDarwinConnect(path: socketURL.path)
        defer { client.close() }
        let major = try IPCJSON.decode(
            HelloAck.self,
            from: client.send(
                body: try IPCJSON.encode(
                    Hello(protocolName: ProtocolVersion.name, clientSemver: "99.0.0")
                )
            )
        )
        #expect(major.status == .skew(.majorVersion))

        let proto = try IPCJSON.decode(
            HelloAck.self,
            from: client.send(
                body: try IPCJSON.encode(
                    Hello(protocolName: "rv.ipc.wrong", clientSemver: "1.0.0")
                )
            )
        )
        #expect(proto.status == .skew(.protocolSkew))
    }

    @Test func garbageBodyIsDecodeFailed() throws {
        let home = try makeIsolatedHome("garbage")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let listener = UnixSocketListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        defer { listener.stop() }

        let client = try retryDarwinConnect(path: socketURL.path)
        defer { client.close() }
        _ = try client.send(body: try IPCJSON.encode(Hello()))
        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: client.send(body: Data("not-json".utf8))
        )
        guard case .error(.decodeFailed) = response.result else {
            Issue.record("garbage body must decode-fail, got \(response.result)")
            return
        }
    }

    @Test func oversizedFrameDropsConnection() throws {
        let home = try makeIsolatedHome("oversize")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let listener = UnixSocketListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        defer { listener.stop() }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        var addr = try DarwinFrameIO.sockaddr(path: socketURL.path)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(connected == 0)
        var header = UInt32(FrameCodec.maxBodyBytes + 1).bigEndian
        let sent = withUnsafeBytes(of: &header) { Darwin.send(fd, $0.baseAddress, 4, 0) }
        try #require(sent == 4)
        var byte: UInt8 = 0
        let received = Darwin.recv(fd, &byte, 1, 0)
        #expect(received <= 0)
    }

    @Test func stopRemovesSocketFile() throws {
        let home = try makeIsolatedHome("stop")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let listener = UnixSocketListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        #expect(FileManager.default.fileExists(atPath: socketURL.path))
        listener.stop()
        #expect(FileManager.default.fileExists(atPath: socketURL.path) == false)
    }

    @Test func sockaddrRejectsPathTooLong() {
        let long = "/" + String(repeating: "x", count: 200)
        #expect(throws: DarwinFrameError.pathTooLong) {
            _ = try DarwinFrameIO.sockaddr(path: long)
        }
    }

    @Test func rvdProcessDeniesResetHard() async throws {
        let rvd = try #require(findDarwinRVDExecutable(), "rvd binary must be built")
        let home = try makeIsolatedHome("rvd-proc")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let process = Process()
        process.executableURL = rvd
        process.arguments = ["--idle-exit-seconds", "30"]
        process.environment = [
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
        ]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        defer {
            process.terminate()
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let client = try retryDarwinConnect(path: socketURL.path, attempts: 80)
        defer { client.close() }
        let ack = try IPCJSON.decode(HelloAck.self, from: client.send(body: try IPCJSON.encode(Hello())))
        #expect(ack.status == .ok)
        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: client.send(body: try IPCJSON.encode(darwinResetHardRequest()))
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("rvd evaluate must return evaluate")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("rvd must deny reset-hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(try UnixSocketPath.posixMode(of: socketURL) & 0o777 == 0o600)
    }

    @Test func rvdProcessWithUnsetHomeExitsOne() throws {
        let rvd = try #require(findDarwinRVDExecutable(), "rvd binary must be built")
        let process = Process()
        process.executableURL = rvd
        process.arguments = []
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "HOME")
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(err.contains("HOME is required"))
    }
}

private func darwinResetHardRequest() -> IPCRequest {
    IPCRequest(
        method: .evaluate(
            EvaluateParams(
                request: EvaluationRequest(
                    command: ShellCommand(rawValue: "git reset --hard"),
                    enabledPacks: dayOnePackIDs
                ),
                clientSemver: ProtocolVersion.serviceSemver
            )
        )
    )
}

/// `/tmp`-rooted fake HOME with a short token: macOS TMPDIR plus a UUID would
/// overflow the 104-byte Darwin `sockaddr_un` budget.
private func makeIsolatedHome(_ label: String) throws -> URL {
    let token = String(UInt32.random(in: .min ... .max), radix: 16)
    let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("rvh-\(label)-\(token)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func findDarwinRVDExecutable() -> URL? {
    if let override = ProcessInfo.processInfo.environment["RV_RVD"] {
        let url = URL(fileURLWithPath: override)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }
    let runner = URL(fileURLWithPath: CommandLine.arguments[0])
    var dir = runner.deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("rvd")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        dir = dir.deletingLastPathComponent()
    }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidate = root.appendingPathComponent(".build/debug/rvd")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    return nil
}
#endif
