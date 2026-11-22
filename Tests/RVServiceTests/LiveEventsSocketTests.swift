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
///
/// Every socket read, write and wait runs in `onOwnThread`, off the
/// cooperative pool: a test blocking a pool thread on rvd's reply starves
/// the tasks that produce it. Expectations stay on the test's task.
@Suite(.serialized)
struct LiveEventsSocketTests {
    /// Measured against a baseline from the same runtime and connection
    /// moments before, with no subscribers: the first evaluation compiles
    /// packs, and a loaded runner slows every hook, stuck subscribers or
    /// not. A hook that queued behind a parked poll would add that poll's
    /// wait (up to 5 s) on top of the baseline.
    @Test func subscribersThatNeverReadDoNotSlowHooks() async throws {
        let run = try await onOwnThread { try Self.hooksBesideStuckSubscribers() }
        for hook in run.hooks {
            #expect(hook.timedOut == false)
            #expect(hook.took < run.baseline + .seconds(2),
                    "\(hook.command) took \(hook.took) with stuck subscribers; baseline \(run.baseline)")
        }
    }

    @Test func sameUserSocketPeerReadsDecisions() async throws {
        let decision = try await onOwnThread { try Self.decisionReadOverTheSocket() }
        let seen = try #require(decision)
        #expect(seen.verdict == .denied)
        #expect(seen.rule == "core.git:reset-hard")
        #expect(seen.command == "git reset --hard")
    }

    /// A peer that pipelines polls and never reads fills its socket with
    /// replies; rvd gives up on the reply after the send timeout, closes
    /// that connection and frees its slot for the next client.
    @Test func aPeerThatPipelinesPollsAndNeverReadsLosesItsSlot() async throws {
        let served = try await onOwnThread { try Self.slotFreedAfterAPipelinedPeer() }
        #expect(served, "a peer that never reads must not hold its connection slot")
    }

    // MARK: - Blocking bodies (run off the pool)

    private struct TimedHook: Sendable {
        let command: String
        let took: Duration
        let timedOut: Bool
    }

    private struct StuckRun: Sendable {
        let baseline: Duration
        let hooks: [TimedHook]
    }

    private static func hooksBesideStuckSubscribers() throws -> StuckRun {
        let xdg = try makeXDG("events-stuck")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let runtime = try isolatedRuntime()
        let bus = runtime.events
        let listener = UnixEvaluateListener(
            runtime: runtime, watchdog: IdleWatchdog(seconds: 300), socketURL: socketURL)
        try listener.start()
        defer { listener.stop() }

        let commands = ["git status", "git reset --hard", "git status"]
        let client = try retryUnixConnect(path: socketURL.path)
        defer { client.close() }
        _ = try timedHook(client, "git status")  // warm-up: pack compile
        var baseline = Duration.zero
        for command in commands { baseline = max(baseline, try timedHook(client, command).took) }

        // More stuck subscribers than the wire waiter cap: each says hello,
        // queues long polls, and never reads a byte back.
        var stuck: [Int32] = []
        defer { stuck.forEach { _ = Glibc.close($0) } }
        for _ in 0..<(LiveEventBus.maxWireWaiters + 4) {
            let fd = try connectRaw(socketURL.path)
            stuck.append(fd)
            try UnixFrameIO.writeFrame(fd: fd, body: IPCJSON.encode(Hello()))
            let poll = try IPCJSON.encode(IPCRequest(method: .events(EventsParams(waitMs: EventsParams.maxWaitMs))))
            for _ in 0..<16 { try UnixFrameIO.writeFrame(fd: fd, body: poll) }
        }

        var hooks: [TimedHook] = []
        for command in commands {
            // The last hook's decision has woken the parked polls; the hook
            // goes out only once a full set is parked again.
            let published = bus.head
            guard waitUntil({ bus.wireWaiters == LiveEventBus.maxWireWaiters }) else {
                throw SocketEventsError.unexpected("stuck subscribers never parked a full set of polls")
            }
            let (reply, took) = try timedHook(client, command)
            hooks.append(TimedHook(command: command, took: took, timedOut: reply.stdout.contains("timed out")))
            _ = waitUntil { bus.head > published }
        }
        return StuckRun(baseline: baseline, hooks: hooks)
    }

    private static func decisionReadOverTheSocket() throws -> LiveDecision? {
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

        var cursor = first.cursor
        for _ in 0..<10 {
            let reply = try events(subscriber, EventsParams(stream: first.stream, after: cursor, waitMs: 2_000))
            cursor = reply.cursor
            for event in reply.events {
                if case .decision(let decision) = event.payload { return decision }
            }
        }
        return nil
    }

    private static func slotFreedAfterAPipelinedPeer() throws -> Bool {
        let xdg = try makeXDG("events-pipelined")
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socketURL = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        let runtime = try isolatedRuntime()
        let wide = String(repeating: "x", count: 400)
        for _ in 0..<LiveEventBus.defaultCapacity {
            runtime.events.publish(.decision(LiveDecision(
                verdict: .allowed, host: .claude, tool: .bash, command: wide)), at: Date())
        }
        let listener = UnixEvaluateListener(
            runtime: runtime, watchdog: IdleWatchdog(seconds: 300), socketURL: socketURL,
            limits: UnixConnectionLimits(maxConnections: 1, receiveTimeoutSeconds: 30, sendTimeoutSeconds: 1))
        try listener.start()
        defer { listener.stop() }

        // Each answer is a full 64-event batch (~30 KB); 200 of them is far
        // past what the socket buffers hold.
        let stuck = try connectRaw(socketURL.path)
        defer { _ = Glibc.close(stuck) }
        try UnixFrameIO.writeFrame(fd: stuck, body: IPCJSON.encode(Hello()))
        let poll = try IPCJSON.encode(IPCRequest(method: .events(EventsParams(after: 0))))
        for _ in 0..<200 { try UnixFrameIO.writeFrame(fd: stuck, body: poll) }

        // The only slot is the stuck peer's until rvd drops it.
        return waitUntil {
            guard let client = try? retryUnixConnect(path: socketURL.path, attempts: 1) else { return false }
            defer { client.close() }
            guard let data = try? client.send(body: IPCJSON.encode(Hello())),
                  let ack = try? IPCJSON.decode(HelloAck.self, from: data)
            else { return false }
            return ack.status == .ok
        }
    }

    private static func events(_ client: UnixEvaluateClient, _ params: EventsParams) throws -> EventsReply {
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

private func timedHook(
    _ client: UnixEvaluateClient, _ command: String
) throws -> (reply: HookEvaluateReply, took: Duration) {
    let clock = ContinuousClock()
    let started = clock.now
    let response = try IPCJSON.decode(
        IPCResponse.self, from: client.send(body: IPCJSON.encode(hookRequest(command))))
    let took = clock.now - started
    guard case .hookEvaluate(let reply) = response.result else {
        throw SocketEventsError.unexpected("hookEvaluate must answer, got \(response.result)")
    }
    return (reply, took)
}

/// Runs blocking socket work on a thread of its own and suspends the
/// caller until it finishes, keeping the cooperative pool free.
private func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let result: Result<T, any Error> = await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: Result(catching: body)) }
    }
    return try result.get()
}

/// Polls `condition` for up to 30 s; whether it came true.
private func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        Glibc.usleep(5_000)
    }
    return condition()
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
