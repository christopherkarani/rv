#if canImport(Darwin)
import Darwin
import Foundation
import RVDomain
import RVIPC
import Testing
@testable import RVService

/// `events` over rvd's real macOS Unix socket: the owner (the peer
/// `getpeereid` matched at accept) subscribes and reads a hook's decision.
/// The socket work runs on its own thread, off the cooperative pool.
@Suite(.serialized)
struct LiveEventsMacSocketTests {
    @Test func ownerReadsDecisionsOverTheMacSocket() async throws {
        let decision = try await onOwnThread { try Self.decisionReadOverTheSocket() }
        let seen = try #require(decision)
        #expect(seen.verdict == .denied)
        #expect(seen.rule == "core.git:reset-hard")
    }

    private static func decisionReadOverTheSocket() throws -> LiveDecision? {
        // `/tmp` keeps the socket path inside Darwin's 104-byte sockaddr_un.
        let token = String(UInt32.random(in: .min ... .max), radix: 16)
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rvh-events-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = try UnixSocketPath.resolve(homeDirectory: home.path)
        let listener = UnixSocketListener(
            runtime: try isolatedRuntime(), watchdog: IdleWatchdog(seconds: 300), socketURL: socketURL)
        try listener.start()
        defer { listener.stop() }

        let subscriber = try retryDarwinConnect(path: socketURL.path)
        defer { subscriber.close() }
        _ = try subscriber.send(body: IPCJSON.encode(Hello()))
        let first = try poll(subscriber, EventsParams())

        let hook = try retryDarwinConnect(path: socketURL.path)
        defer { hook.close() }
        let input: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "abc-123", "cwd": "/tmp/rv-hook-fixture",
            "tool_name": "Bash", "tool_input": ["command": "git reset --hard"],
        ]
        let stdin = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        _ = try hook.send(body: IPCJSON.encode(IPCRequest(method: .hookEvaluate(HookEvaluateParams(
            host: .claude, stdin: stdin, clientSemver: ProtocolVersion.serviceSemver)))))

        var cursor = first.cursor
        for _ in 0..<10 {
            let reply = try poll(subscriber, EventsParams(stream: first.stream, after: cursor, waitMs: 2_000))
            cursor = reply.cursor
            for event in reply.events {
                if case .decision(let decision) = event.payload { return decision }
            }
        }
        return nil
    }

    private static func poll(_ client: DarwinEvaluateClient, _ params: EventsParams) throws -> EventsReply {
        let response = try IPCJSON.decode(
            IPCResponse.self, from: client.send(body: IPCJSON.encode(IPCRequest(method: .events(params)))))
        guard case .events(let reply) = response.result else {
            throw MacSocketEventsError.unexpected("the owner must read events, got \(response.result)")
        }
        return reply
    }
}

private enum MacSocketEventsError: Error {
    case unexpected(String)
}

/// Runs blocking socket work on a thread of its own and suspends the
/// caller until it finishes, keeping the cooperative pool free.
private func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let result: Result<T, any Error> = await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: Result(catching: body)) }
    }
    return try result.get()
}
#endif
