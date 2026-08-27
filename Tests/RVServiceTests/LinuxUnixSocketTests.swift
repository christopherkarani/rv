#if os(Linux)
#if canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

@Suite(.serialized)
struct LinuxUnixSocketTests {
    @Test func inProcessMissStillDeniesResetHard() async throws {
        let gated = GatedEvaluate()
        let result = await gated.run(
            .apply,
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws"),
            home: HomeDirectory(validating: try isolatedHomeDirectory().path),
            store: AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory()),
            now: Date(timeIntervalSince1970: 1_700_000_000),
            allowlist: { .empty }
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("in-process evaluate must deny reset-hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func listenerOnInjectedXDGDeniesResetHardAndModesAreOwnerOnly() async throws {
        let xdg = try makeInjectedXDG("listener")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let runtime = try isolatedRuntime()
        let listener = UnixEvaluateListener(
            runtime: runtime,
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        defer { listener.stop() }

        #expect(try UnixSocketPath.posixMode(xdg) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(socketURL.deletingLastPathComponent()) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(socketURL) & 0o777 == 0o600)

        let client = try retryUnixConnect(path: socketURL.path)
        defer { client.close() }
        let ack = try IPCJSON.decode(HelloAck.self, from: client.send(body: try IPCJSON.encode(Hello())))
        #expect(ack.status == .ok)

        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: client.send(body: try IPCJSON.encode(resetHardRequest()))
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("socket evaluate must return evaluate")
            return
        }
        #expect(reply.via == .xpc)
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("socket evaluate must deny reset-hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func rvdSocketProcessDeniesResetHard() async throws {
        let rvd = try #require(findRVDExecutable(), "rvd binary must be built with the Linux graph")
        let xdg = try makeInjectedXDG("rvd-proc")
        let home = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: xdg)
            try? FileManager.default.removeItem(at: home)
        }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let process = Process()
        process.executableURL = rvd
        process.arguments = ["--socket", "--idle-exit-seconds", "2"]
        process.environment = [
            "XDG_RUNTIME_DIR": xdg.path,
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        defer {
            process.terminate()
            if process.isRunning {
                _ = Glibc.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let client = try retryUnixConnect(path: socketURL.path, attempts: 80)
        defer { client.close() }
        let ack = try IPCJSON.decode(HelloAck.self, from: client.send(body: try IPCJSON.encode(Hello())))
        #expect(ack.status == .ok)
        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: client.send(body: try IPCJSON.encode(resetHardRequest()))
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("rvd --socket evaluate must return evaluate")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("rvd --socket must deny reset-hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(try UnixSocketPath.posixMode(socketURL) & 0o777 == 0o600)
        #expect(try UnixSocketPath.posixMode(xdg) & 0o777 == 0o700)
    }

    @Test func rvdSocketWithUnsetXDGExitsWithoutTmpSocket() throws {
        let rvd = try #require(findRVDExecutable(), "rvd binary must be built with the Linux graph")
        let home = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = rvd
        process.arguments = ["--socket"]
        process.environment = [
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(err.contains("XDG_RUNTIME_DIR is required"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/rv.sock") == false)
        #expect(FileManager.default.fileExists(atPath: "/tmp/evaluate.sock") == false)
    }
}

private func resetHardRequest() -> IPCRequest {
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

private func makeInjectedXDG(_ label: String) throws -> URL {
    let xdg = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-xdg-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
    return xdg
}

private func findRVDExecutable() -> URL? {
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
    let build = root.appendingPathComponent(".build")
    let names = [
        "debug/rvd",
        "x86_64-unknown-linux-gnu/debug/rvd",
        "aarch64-unknown-linux-gnu/debug/rvd",
    ]
    for name in names {
        let candidate = build.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}
#endif
