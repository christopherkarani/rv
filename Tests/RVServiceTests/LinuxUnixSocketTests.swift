#if os(Linux)
#if canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
import Synchronization
@testable import RVService

@Suite(.serialized)
struct LinuxUnixSocketTests {
    @Test func inProcessMissStillDeniesResetHard() async throws {
        let gated = GatedEvaluate()
        let result = await gated.apply(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws"),
            home: HomeDirectory(validating: try isolatedHomeDirectory().path),
            grants: EphemeralAllowOnceTable(),
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

        #expect(try UnixSocketPath.posixMode(of: xdg) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(of: socketURL.deletingLastPathComponent()) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(of: socketURL) & 0o777 == 0o600)

        let client = try retryUnixConnect(path: socketURL.path)
        defer { client.close() }
        let ack = try IPCJSON.decode(HelloAck.self, from: await client.exchange(body: try IPCJSON.encode(Hello())))
        #expect(ack.status == .ok)

        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: await client.exchange(body: try IPCJSON.encode(resetHardRequest()))
        )
        // Same-UID SDK socket runs evaluate. Generic dispatch still denies it
        // (SocketPeerAuthorizationTests.socketPeerHasNoControlOrEvalAuthority).
        guard case .evaluate(let reply) = response.result else {
            Issue.record("socket evaluate must return evaluate, got \(response.result)")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("socket evaluate must deny reset-hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func silentIdleConnectionDoesNotStarveSecondClient() async throws {
        let xdg = try makeInjectedXDG("idle")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let listener = UnixEvaluateListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.start()
        defer { listener.stop() }

        // Connected, never sends a byte: its serve loop parks in recv. Serving
        // on the serial accept queue would starve the second client behind it.
        let idle = try retryUnixConnect(path: socketURL.path)
        defer { idle.close() }
        let second = try retryUnixConnect(path: socketURL.path)
        defer { second.close() }
        let box = LinuxReplyBox()
        let done = DispatchSemaphore(value: 0)
        let held = LinuxUncheckedClient(second)
        Thread.detachNewThread {
            box.set(try? held.client.send(body: (try? IPCJSON.encode(Hello())) ?? Data()))
            done.signal()
        }
        guard await signaled(done, within: 5), let data = box.get() else {
            Issue.record("second client was not served while an idle connection was open")
            return
        }
        #expect(try IPCJSON.decode(HelloAck.self, from: data).status == .ok)
    }

    /// rvd binds before its startup backoff wait and accepts after it. The
    /// hook's connect then succeeds into the backlog and its read times out
    /// (TIMEOUT: ask/deny), never ENOENT/ECONNREFUSED (UNREACHABLE, which
    /// observe mode steps aside for).
    @Test func boundButNotAcceptingQueuesClientsUntilAccepting() async throws {
        let xdg = try makeInjectedXDG("hold")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let listener = UnixEvaluateListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.bind()
        defer { listener.stop() }

        let client = try retryUnixConnect(path: socketURL.path)
        defer { client.close() }
        let box = LinuxReplyBox()
        let done = DispatchSemaphore(value: 0)
        let held = LinuxUncheckedClient(client)
        Thread.detachNewThread {
            box.set(try? held.client.send(body: (try? IPCJSON.encode(Hello())) ?? Data()))
            done.signal()
        }
        #expect(await signaled(done, within: 1.5) == false, "nothing answers before accepting")
        listener.startAccepting()
        guard await signaled(done, within: 5), let data = box.get() else {
            Issue.record("queued client was not served once the listener accepted")
            return
        }
        #expect(try IPCJSON.decode(HelloAck.self, from: data).status == .ok)
    }

    /// After a backoff wait, connections that queued during it are hung up,
    /// not served late; a client connecting once rvd accepts is served.
    @Test func droppedQueuedClientsAreHungUpAndLaterOnesServed() async throws {
        let xdg = try makeInjectedXDG("drop")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let listener = UnixEvaluateListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.bind()
        defer { listener.stop() }

        let client = try retryUnixConnect(path: socketURL.path)
        defer { client.close() }
        let box = LinuxReplyBox()
        let done = DispatchSemaphore(value: 0)
        let held = LinuxUncheckedClient(client)
        let hello = try IPCJSON.encode(Hello())
        Thread.detachNewThread {
            box.set(try? held.client.send(body: hello))
            done.signal()
        }
        #expect(await signaled(done, within: 0.5) == false, "nothing answers before accepting")
        listener.dropQueued()
        listener.startAccepting()
        #expect(await signaled(done, within: 5))
        #expect(box.get() == nil, "a queued client is hung up, not served")

        let later = try retryUnixConnect(path: socketURL.path)
        defer { later.close() }
        #expect(try IPCJSON.decode(HelloAck.self, from: try await later.exchange(body: hello)).status == .ok)
    }

    @Test func stopWhileNotAcceptingRemovesTheSocket() async throws {
        let xdg = try makeInjectedXDG("holdstop")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let listener = UnixEvaluateListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        try listener.bind()
        #expect(FileManager.default.fileExists(atPath: socketURL.path))
        listener.stop()
        #expect(FileManager.default.fileExists(atPath: socketURL.path) == false)
    }

    @Test func stopWithoutStartRemovesNothing() async throws {
        let xdg = try makeInjectedXDG("nostart")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-ours".utf8).write(to: socketURL)
        let listener = UnixEvaluateListener(
            runtime: try isolatedRuntime(),
            watchdog: IdleWatchdog(seconds: 300),
            socketURL: socketURL
        )
        listener.stop()
        #expect(try Data(contentsOf: socketURL) == Data("not-ours".utf8))
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
        let ack = try IPCJSON.decode(HelloAck.self, from: await client.exchange(body: try IPCJSON.encode(Hello())))
        #expect(ack.status == .ok)
        let response = try IPCJSON.decode(
            IPCResponse.self,
            from: await client.exchange(body: try IPCJSON.encode(resetHardRequest()))
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("rvd --socket evaluate must return evaluate, got \(response.result)")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("rvd --socket must deny reset-hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(try UnixSocketPath.posixMode(of: socketURL) & 0o777 == 0o600)
        #expect(try UnixSocketPath.posixMode(of: xdg) & 0o777 == 0o700)
    }

    /// Unset XDG_RUNTIME_DIR now means the uid-derived `/run/user/<uid>`
    /// (`UnixSocketPathTests` covers that against a fixture root; a process
    /// test must never bind the real one). Set but empty still fails closed,
    /// with no /tmp fallback.
    @Test func rvdSocketWithEmptyXDGExitsWithoutTmpSocket() async throws {
        let rvd = try #require(findRVDExecutable(), "rvd binary must be built with the Linux graph")
        let home = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = rvd
        process.arguments = ["--socket"]
        process.environment = [
            "XDG_RUNTIME_DIR": "",
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
        #expect(err.contains("XDG_RUNTIME_DIR is set but empty"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/rv.sock") == false)
        #expect(FileManager.default.fileExists(atPath: "/tmp/evaluate.sock") == false)
    }
}

/// Test-only shared box for one reply from a worker thread.
private final class LinuxReplyBox: Sendable {
    private let box = Mutex<Data?>(nil)

    func set(_ data: Data?) { box.withLock { $0 = data } }
    func get() -> Data? { box.withLock { $0 } }
}

private struct LinuxUncheckedClient: @unchecked Sendable {
    let client: UnixEvaluateClient

    init(_ client: UnixEvaluateClient) {
        self.client = client
    }
}

/// Whether `semaphore` is signaled within `seconds`, waiting off the
/// cooperative pool: the listener answers from a `Task` on that pool.
private func signaled(_ semaphore: DispatchSemaphore, within seconds: Double) async -> Bool {
    await offPool { semaphore.wait(timeout: .now() + seconds) == .success }
}

extension UnixEvaluateClient {
    /// `send(body:)` off the cooperative pool. The listener answers from a
    /// `Task`, so a test blocked in recv on a pool thread can starve it.
    fileprivate func exchange(body: Data) async throws -> Data {
        let held = LinuxUncheckedClient(self)
        return try await offPool { try held.client.send(body: body) }
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
