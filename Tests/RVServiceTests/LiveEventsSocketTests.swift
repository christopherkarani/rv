#if os(Linux)
#if canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIPC
import Synchronization
import Testing
@testable import RVService

/// `events` over rvd's real Unix socket: subscribers that send polls and
/// never read the replies do not slow a hook on another connection, and
/// the socket's same-uid peer reads events end to end.
@Suite(.serialized)
struct LiveEventsSocketTests {
    @Test func subscribersThatNeverReadDoNotSlowHooks() throws {
        let xdg = try makeXDG("events-stuck")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let listener = UnixEvaluateListener(
            runtime: try isolatedRuntime(), watchdog: IdleWatchdog(seconds: 300), socketURL: socketURL)
        try listener.start()
        defer { listener.stop() }

        // More stuck subscribers than the wire waiter cap: each says hello,
        // queues long polls, and never reads a byte back.
        var stuck: [Int32] = []
        defer { stuck.forEach { _ = Glibc.close($0) } }
        for _ in 0..<(LiveEventBus.maxWireWaiters + 4) {
            let fd = try connectRaw(socketURL.path)
            stuck.append(fd)
            try UnixFrameIO.writeFrame(fd: fd, body: IPCJSON.encode(Hello()))
            let poll = try IPCJSON.encode(IPCRequest(method: .events(EventsParams(waitMs: EventsParams.maxWaitMs))))
            for _ in 0..<3 { try UnixFrameIO.writeFrame(fd: fd, body: poll) }
        }

        let client = try retryUnixConnect(path: socketURL.path)
        defer { client.close() }
        let clock = ContinuousClock()
        for command in ["git status", "git reset --hard", "git status"] {
            let started = clock.now
            let response = try IPCJSON.decode(
                IPCResponse.self, from: client.send(body: IPCJSON.encode(hookRequest(command))))
            let took = clock.now - started
            guard case .hookEvaluate(let reply) = response.result else {
                Issue.record("hookEvaluate must answer, got \(response.result)")
                return
            }
            #expect(reply.stdout.contains("timed out") == false)
            // Far under the 7 s hook budget; a hook queued behind a stuck
            // subscriber would wait out the 5 s poll.
            #expect(took < .seconds(2), "\(command) took \(took) with stuck subscribers")
        }
    }

    @Test func sameUserSocketPeerReadsDecisions() throws {
        let xdg = try makeXDG("events-read")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let listener = UnixEvaluateListener(
            runtime: try isolatedRuntime(), watchdog: IdleWatchdog(seconds: 300), socketURL: socketURL)
        try listener.start()
        defer { listener.stop() }

        let subscriber = try retryUnixConnect(path: socketURL.path)
        defer { subscriber.close() }
        _ = try subscriber.send(body: IPCJSON.encode(Hello()))
        let first = try events(subscriber, EventsParams())

        let hook = try retryUnixConnect(path: socketURL.path)
        defer { hook.close() }
        _ = try hook.send(body: IPCJSON.encode(hookRequest("git reset --hard")))

        var decision: LiveDecision?
        var cursor = first.cursor
        for _ in 0..<10 where decision == nil {
            let reply = try events(subscriber, EventsParams(stream: first.stream, after: cursor, waitMs: 2_000))
            cursor = reply.cursor
            decision = reply.events.lazy.compactMap { event -> LiveDecision? in
                if case .decision(let decision) = event.payload { return decision }
                return nil
            }.first
        }
        let seen = try #require(decision)
        #expect(seen.verdict == .denied)
        #expect(seen.rule == "core.git:reset-hard")
        #expect(seen.command == "git reset --hard")
    }

    private func events(_ client: UnixEvaluateClient, _ params: EventsParams) throws -> EventsReply {
        let response = try IPCJSON.decode(
            IPCResponse.self, from: client.send(body: IPCJSON.encode(IPCRequest(method: .events(params)))))
        guard case .events(let reply) = response.result else {
            throw SocketEventsError.unexpected("\(response.result)")
        }
        return reply
    }
}

private enum SocketEventsError: Error {
    case unexpected(String)
}

private func hookRequest(_ command: String) throws -> IPCRequest {
    let input: [String: Any] = [
        "hook_event_name": "PreToolUse", "session_id": "abc-123", "cwd": "/tmp/rv-hook-fixture",
        "tool_name": "Bash", "tool_input": ["command": command],
    ]
    let stdin = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
    return IPCRequest(method: .hookEvaluate(HookEvaluateParams(
        host: .claude, stdin: stdin, clientSemver: ProtocolVersion.serviceSemver)))
}

private func connectRaw(_ path: String) throws -> Int32 {
    let fd = try UnixFrameIO.openStream()
    var address = try UnixFrameIO.sockaddr(path: path)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        _ = Glibc.close(fd)
        throw UnixFrameError.connect
    }
    return fd
}

private func makeXDG(_ label: String) throws -> URL {
    let xdg = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-xdg-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
    return xdg
}
#endif
