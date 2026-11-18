#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// A stdio MCP server that gets stuck. `answers`: initialize and tools/list
/// are answered (one tool, `wait`), tools/call never is. `silent`: nothing
/// is answered. Every method it reads is appended to the file in argv[2].
let stuckServer = #"""
    import json, sys
    mode, seen = sys.argv[1], sys.argv[2]
    for line in sys.stdin:
        msg = json.loads(line)
        with open(seen, "a") as f:
            f.write(str(msg.get("method")) + "\n")
        if "id" not in msg or mode == "silent":
            continue
        method, mid = msg.get("method"), msg["id"]
        if method == "initialize":
            result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "stuck", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "wait", "inputSchema": {"type": "object"}}]}
        else:
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
    """#

/// True once `condition` holds, polled off the concurrency pool for at most
/// `timeout` seconds: a ceiling, not an expected duration.
private func eventuallyAsync(_ timeout: TimeInterval = 90, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    await offThePool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }
}

/// One `MCPGatewayRuntime` over a `LineClient`, recording audits and logs.
final class GatewayRun: Sendable {
    let client: LineClient
    let audits: RecordedAudits
    let logs: RecordedLogs
    let runtime: MCPGatewayRuntime
    private final class EndingBox: Sendable {
        let value = Mutex<MCPGatewayRuntime.Ending?>(nil)
    }

    private let endingBox = EndingBox()
    /// How `run` returned, once it has.
    var ending: MCPGatewayRuntime.Ending? { endingBox.value.withLock { $0 } }
    private let done: DispatchSemaphore

    /// `log`, when given, is called after the line is recorded.
    init(
        core: MCPGatewayCore, connections: [MCPUpstreamConnection],
        writeBufferBytes: Int = MCPGatewayRuntime.writeBufferBytes, log: (@Sendable (String) -> Void)? = nil,
        relaunch: MCPGatewayRuntime.Relaunch? = nil,
        clientStallSeconds: TimeInterval = MCPGatewayRuntime.clientStallSeconds,
        stopGrace: TimeInterval = MCPGatewayRuntime.stopGrace,
        restartWait: TimeInterval? = nil,
        remoteRequestLimit: Int? = nil
    ) {
        let client = LineClient()
        let audits = RecordedAudits()
        let logs = RecordedLogs()
        let done = DispatchSemaphore(value: 0)
        let runtime = MCPGatewayRuntime(
            core: core, connections: connections,
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            writeBufferBytes: writeBufferBytes,
            relaunch: relaunch,
            clientStallSeconds: clientStallSeconds,
            stopGrace: stopGrace,
            restartWait: restartWait,
            remoteRequestLimit: remoteRequestLimit,
            audit: { record in audits.items.withLock { $0.append(record) } },
            log: { line in
                logs.lines.withLock { $0.append(line) }
                log?(line)
            })
        self.client = client
        self.audits = audits
        self.logs = logs
        self.done = done
        self.runtime = runtime
        let box = endingBox
        Thread.detachNewThread {
            let how = runtime.run()
            box.value.withLock { $0 = how }
            done.signal()
        }
    }

    /// Waits for `run` to return without closing the client's input.
    func ended(within seconds: TimeInterval = 60) async -> Bool {
        let done = done
        guard await offThePool({ done.wait(timeout: .now() + seconds) }) == .success else { return false }
        done.signal()
        return true
    }

    /// Every server gets `startTimeout` as its `startTimeoutSeconds`.
    static func core(_ servers: [MCPServerDefinition], startTimeout: Int) -> MCPGatewayCore {
        let servers = servers.map { server in
            var server = server
            server.startTimeoutSeconds = startTimeout
            return server
        }
        return MCPGatewayCore(
            configuration: MCPConfiguration(servers: servers),
            upstreams: servers.map { MCPGatewayCore.Upstream(definition: $0) },
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true }, deadlines: MCPGatewayDeadlines(list: 300))
    }

    func initialize() async -> Bool {
        client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let reply = await client.next(timeout: 120)
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return reply?["result"]?["serverInfo"]?["name"] == .string("rv")
    }

    /// Closes the client's input and waits for `run` to return.
    func finish() async -> Bool {
        try? client.toGateway.fileHandleForWriting.close()
        let done = done
        return await offThePool { done.wait(timeout: .now() + 60) } == .success
    }
}

final class ForwardCount: Sendable {
    let value = Mutex(0)
}

@Suite("MCPGatewayRuntime deadlines", .enabled(if: python3Available))
struct MCPGatewayDeadlineRuntimeTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(stuckServer.utf8).write(to: directory.appendingPathComponent("stuck.py"))
        return directory
    }

    static func launch(_ server: String, mode: String, in directory: URL) -> MCPUpstreamConnection {
        .process(MCPUpstreamLaunch(
            server: server, executable: "/usr/bin/env",
            arguments: [
                "python3", "-u", directory.appendingPathComponent("stuck.py").path, mode,
                directory.appendingPathComponent("\(server).seen").path,
            ],
            environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]))
    }

    static func seen(_ server: String, in directory: URL) -> String {
        (try? String(contentsOf: directory.appendingPathComponent("\(server).seen"), encoding: .utf8)) ?? ""
    }

    @Test func stdioCallThatIsNeverAnsweredFailsAndIsCancelledUpstream() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var slow = MCPServerDefinition(name: "slow", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        slow.callTimeoutSeconds = 1
        let run = GatewayRun(
            core: GatewayRun.core([slow], startTimeout: 300),
            connections: [Self.launch("slow", mode: "answers", in: directory)])
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait","arguments":{}}}"#)
        let reply = await run.client.next(timeout: 120)
        #expect(reply?["id"] == .int(3))
        #expect(reply?["error"]?["code"] == .int(-32603))
        #expect(reply?["error"]?["message"]?.stringValue?.contains("within 1 s") == true, "\(String(describing: reply))")
        let audits = run.audits
        #expect(await eventuallyAsync {
            audits.items.withLock { $0.contains { $0.outcome == .interrupted(grant: nil) && $0.reason?.contains("timed out") == true } }
        })
        #expect(await eventuallyAsync { Self.seen("slow", in: directory).contains("notifications/cancelled") })
        #expect(Self.seen("slow", in: directory).components(separatedBy: "tools/call").count == 2)
        #expect(await run.finish())
    }

    /// A call still in flight when serving ends has its one terminal
    /// record (it may still have run) before `run` returns.
    @Test(.timeLimit(.minutes(5)))
    func aCallInFlightWhenServingEndsIsInterrupted() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slow = MCPServerDefinition(name: "slow", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        let run = GatewayRun(
            core: GatewayRun.core([slow], startTimeout: 300),
            connections: [Self.launch("slow", mode: "answers", in: directory)])
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait","arguments":{}}}"#)
        #expect(await eventuallyAsync { Self.seen("slow", in: directory).contains("tools/call") })
        #expect(await run.finish())
        let records = run.audits.items.withLock { $0 }
        #expect(records.count == 1, "\(records)")
        #expect(records.first?.outcome == .interrupted(grant: nil))
        #expect(records.first?.reason == "gateway stopped; the call may still have run")
    }

    /// Once serving is stopping, a client line is not handled: nothing is
    /// recorded as forwarded for a call that can go nowhere.
    @Test(.timeLimit(.minutes(5)))
    func clientLinesAfterServingStopsAreNotHandled() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slow = MCPServerDefinition(name: "slow", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        let counted = ForwardCount()
        let core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: [slow]), upstreams: [MCPGatewayCore.Upstream(definition: slow)],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced,
            recordForward: { _ in
                counted.value.withLock { $0 += 1 }
                return true
            })
        let run = GatewayRun(core: core, connections: [Self.launch("slow", mode: "answers", in: directory)])
        defer { run.stopNow() }
        #expect(await run.initialize())
        // The same call is forwarded while serving.
        run.client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(await run.client.next(timeout: 120)?["id"] == .int(2))
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait","arguments":{}}}"#)
        #expect(await eventuallyAsync { counted.value.withLock { $0 } == 1 })
        run.runtime.requestShutdown()
        #expect(await run.ended(within: 90))
        run.client.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"wait","arguments":{}}}"#)
        let handled = await eventuallyAsync(3) { counted.value.withLock { $0 } > 1 }
        #expect(handled == false)
        try? run.client.toGateway.fileHandleForWriting.close()
    }

    @Test func serverThatNeverAnswersInitializeIsKilledAndReleasesTheClient() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = MCPServerDefinition(name: "silent", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        let run = GatewayRun(
            core: GatewayRun.core([silent], startTimeout: 1),
            connections: [Self.launch("silent", mode: "silent", in: directory)])
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let listed = await run.client.next(timeout: 120)
        #expect(listed?["id"] == .int(2))
        #expect(listed?["result"]?["tools"] == .array([]))
        let logs = run.logs
        #expect(await eventuallyAsync { logs.text.contains("MCP server silent exited") }, "\(logs.text)")
        #expect(logs.text.contains("did not answer initialize within 1 s"))
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait","arguments":{}}}"#)
        let call = await run.client.next(timeout: 120)
        #expect(call?["error"]?["message"]?.stringValue?.contains("did not answer initialize") == true)
        #expect(await run.finish())
    }

    /// A stop asks first: SIGTERM, then SIGKILL once the grace has passed.
    /// The server notes the SIGTERM and carries on, so only the SIGKILL ends
    /// it. It is stopped for answering `initialize` with an error, sent only
    /// once its handler is in place.
    @Test func aStoppedServerGetsSIGTERMThenSIGKILL() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = #"""
            import json, signal, sys, time
            def term(signum, frame):
                with open(sys.argv[1], "w") as f:
                    f.write("term")
            signal.signal(signal.SIGTERM, term)
            msg = json.loads(sys.stdin.readline())
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -1, "message": "no"}}), flush=True)
            while True:
                time.sleep(0.05)
            """#
        try Data(script.utf8).write(to: directory.appendingPathComponent("stubborn.py"))
        let marker = directory.appendingPathComponent("term")
        let stubborn = MCPServerDefinition(name: "stubborn", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        // A grace wider than serve's 2 s, so a loaded machine still runs the
        // handler before the SIGKILL.
        let run = GatewayRun(
            core: GatewayRun.core([stubborn], startTimeout: 300),
            connections: [.process(MCPUpstreamLaunch(
                server: "stubborn", executable: "/usr/bin/env",
                arguments: ["python3", "-u", directory.appendingPathComponent("stubborn.py").path, marker.path],
                environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]))],
            stopGrace: 10)
        defer { run.stopNow() }
        #expect(await run.initialize())
        let logs = run.logs
        #expect(await eventuallyAsync { logs.text.contains("MCP server stubborn exited") }, "\(logs.text)")
        #expect(logs.text.contains("failed to initialize"))
        // A stop is reported at once, when SIGTERM is sent, so the handler
        // may not have run yet.
        #expect(await eventuallyAsync { (try? String(contentsOf: marker, encoding: .utf8)) == "term" })
        #expect(await run.finish())
    }

    @Test func legacySSECallAcceptedButNeverAnsweredFails() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        var legacy = MCPServerDefinition(
            name: "legacy", remote: MCPRemoteServer(url: fixture.url("/sse"), transport: .sse),
            tools: MCPToolPolicy(allow: ["*"]))
        legacy.callTimeoutSeconds = 1
        let run = GatewayRun(
            core: GatewayRun.core([legacy], startTimeout: 300),
            connections: [.remote(MCPRemoteLaunch(server: "legacy", url: fixture.url("/sse"), transport: .sse))])
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}"#)
        let reply = await run.client.next(timeout: 120)
        #expect(reply?["id"] == .int(3))
        #expect(reply?["error"]?["message"]?.stringValue?.contains("within 1 s") == true, "\(String(describing: reply))")
        // Before the stop, which would cancel a POST still on its way.
        #expect(await eventuallyAsync(60) { fixture.requests().contains("REQ POST /sse notifications/cancelled") },
            "\(fixture.requests())")
        #expect(await run.finish())
        let requests = await offThePool { fixture.stop() }
        #expect(requests.contains("REQ POST /sse tools/call"), "\(requests)")
    }

    /// The core's deadline fires, not the HTTP layer's: the call fails with
    /// the gateway's own answer and audit record, the server is asked to
    /// cancel, and the call's quiet POST is closed then, not held open.
    @Test func streamableHTTPCallNeverAnsweredFailsCancelsAndClosesItsRequest() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        var remote = MCPServerDefinition(
            name: "remote", remote: MCPRemoteServer(url: fixture.url("/mcp")), tools: MCPToolPolicy(allow: ["*"]))
        remote.callTimeoutSeconds = 1
        let run = GatewayRun(
            core: GatewayRun.core([remote], startTimeout: 300),
            connections: [.remote(MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")))])
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}"#)
        let reply = await run.client.next(timeout: 120)
        #expect(reply?["id"] == .int(3))
        #expect(reply?["error"]?["message"]?.stringValue?.contains("did not answer tool echo within 1 s") == true,
            "\(String(describing: reply))")
        let audits = run.audits
        #expect(await eventuallyAsync {
            audits.items.withLock { $0.contains { $0.outcome == .interrupted(grant: nil) && $0.reason?.contains("timed out") == true } }
        })
        #expect(await eventuallyAsync(60) {
            let requests = fixture.requests()
            return requests.contains("REQ POST /mcp notifications/cancelled") && requests.contains("CLOSED call")
        }, "\(fixture.requests())")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A client's cancel of a call in flight is passed on and closes the
    /// call's quiet POST then, not at the HTTP layer's limit.
    @Test(.timeLimit(.minutes(5)))
    func aClientCancelClosesTheCallsRequest() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let remote = MCPServerDefinition(
            name: "remote", remote: MCPRemoteServer(url: fixture.url("/mcp")), tools: MCPToolPolicy(allow: ["*"]))
        let run = GatewayRun(
            core: GatewayRun.core([remote], startTimeout: 300),
            connections: [.remote(MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")))])
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}"#)
        #expect(await eventuallyAsync { fixture.requests().contains("REQ POST /mcp tools/call") })
        run.client.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#)
        #expect(await eventuallyAsync(60) {
            let requests = fixture.requests()
            return requests.contains("REQ POST /mcp notifications/cancelled") && requests.contains("CLOSED call")
        }, "\(fixture.requests())")
        let audits = run.audits
        #expect(await eventuallyAsync { audits.items.withLock { $0.contains { $0.reason == "cancelled by client" } } })
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// The HTTP layer giving up on a quiet request is not the server's
    /// answer: nothing is delivered for it, so it is never recorded as run;
    /// the core's own, shorter deadline ends it.
    @Test func aRequestTheHTTPLayerGivesUpOnGetsNoAnswer() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let delivered = RecordedMessages()
        let logs = RecordedLogs()
        let remote = MCPRemoteUpstream(
            // Also the limit on initialize (and its connect), so not 1 s on
            // a loaded machine; the call hangs until rv closes it.
            launch: MCPRemoteLaunch(server: "quiet", url: fixture.url("/mcp"), answerTimeout: 5),
            deliver: { message in delivered.items.withLock { $0.append(message) } },
            exited: {},
            log: { line in logs.lines.withLock { $0.append(line) } })
        remote.start()
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)))
        #expect(await eventuallyAsync { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#.utf8)))
        #expect(await eventuallyAsync(60) { logs.text.contains("rv stopped waiting at the HTTP level") }, "\(logs.text)")
        #expect(delivered.items.withLock { $0.contains { $0["id"] == .int(2) } } == false)
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }

    @Test func theHTTPLayerOutwaitsEveryGatewayLimit() {
        for (call, start) in [(1, 600), (300, 60), (86_400, 1), (1, 1)] {
            let timeout = MCPRemoteLaunch.answerTimeout(callTimeoutSeconds: call, startTimeoutSeconds: start)
            #expect(timeout > TimeInterval(call) * MCPGatewayCore.callTimeoutCeilingFactor)
            #expect(timeout > TimeInterval(start))
            #expect(timeout > MCPGatewayDeadlines.standardList)
        }
        #expect(MCPRemoteLaunch(server: "s", url: URL(string: "https://a.example/mcp")!).answerTimeout
            == MCPRemoteLaunch.answerTimeout(
                callTimeoutSeconds: MCPServerDefinition.defaultCallTimeoutSeconds,
                startTimeoutSeconds: MCPServerDefinition.defaultStartTimeoutSeconds))
    }
}

final class RecordedMessages: Sendable {
    let items = Mutex<[JSONValue]>([])
}
