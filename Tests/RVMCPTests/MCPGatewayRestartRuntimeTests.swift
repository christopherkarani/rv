#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// A stdio server that can be made to go away. Every start appends
/// `start <pid>` to argv[1]. Tools: `echo` (answers `text`), `crash` (exits
/// at once, unanswered), `hang` (never answers, nor any ping after it).
/// Options after argv[2]: `child` forks a child in its group, `setsid-child`
/// one in a session of its own (both hold its stdout and write their pid to
/// argv[1].child), `ignore-term` ignores SIGTERM, `deaf` never reads after
/// the listing, `refuse` answers initialize with an error.
let restartingServer = #"""
    import json, os, signal, sys, time
    launches, options = sys.argv[1], sys.argv[2:]
    with open(launches, "a") as f:
        f.write("start %d\n" % os.getpid())
    if "ignore-term" in options:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for kind in ("child", "setsid-child"):
        if kind not in options:
            continue
        # The server goes on only once its child's pid is written: a stop
        # that comes at once (`refuse`) must not kill the child first.
        written, wait = os.pipe()
        if os.fork() == 0:
            if kind == "setsid-child":
                os.setsid()
            with open(launches + ".child", "a") as f:
                f.write("%d\n" % os.getpid())
            os.write(wait, b"x")
            time.sleep(600)
            os._exit(0)
        os.close(wait)
        os.read(written, 1)
        os.close(written)
    hung = False
    def send(mid, result):
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        if mid is None:
            continue
        if method == "initialize":
            if "refuse" in options:
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -1, "message": "no"}}), flush=True)
                continue
            send(mid, {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                       "serverInfo": {"name": "restarting", "version": "1"}})
        elif method == "tools/list":
            send(mid, {"tools": [{"name": n, "inputSchema": {"type": "object"}} for n in ("echo", "crash", "hang")]})
            if "deaf" in options:
                time.sleep(600)
        elif method == "ping":
            if not hung:
                send(mid, {})
        elif method == "tools/call":
            name = msg["params"]["name"]
            if name == "crash":
                os._exit(3)
            if name == "hang":
                hung = True
                continue
            text = msg["params"].get("arguments", {}).get("text", "")
            send(mid, {"content": [{"type": "text", "text": text}]})
    """#

private func eventually(_ timeout: TimeInterval = 90, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    await offThePool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }
}

final class ForwardRecords: Sendable {
    let items = Mutex<[MCPCallRecord]>([])
}

@Suite("MCPGatewayRuntime restarts", .enabled(if: python3Available))
struct MCPGatewayRestartRuntimeTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(restartingServer.utf8).write(to: directory.appendingPathComponent("server.py"))
        return directory
    }

    static func launch(_ options: [String], in directory: URL) -> MCPUpstreamLaunch {
        MCPUpstreamLaunch(
            server: "flaky", executable: "/usr/bin/env",
            arguments: ["python3", "-u", directory.appendingPathComponent("server.py").path,
                        directory.appendingPathComponent("launches").path] + options,
            environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"])
    }

    static func definition(callTimeout: Int = 300) -> MCPServerDefinition {
        var server = MCPServerDefinition(name: "flaky", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        server.callTimeoutSeconds = callTimeout
        return server
    }

    static func core(callTimeout: Int = 300, forwards: ForwardRecords = ForwardRecords()) -> MCPGatewayCore {
        let server = definition(callTimeout: callTimeout)
        return MCPGatewayCore(
            configuration: MCPConfiguration(servers: [server]), upstreams: [MCPGatewayCore.Upstream(definition: server)],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced,
            recordForward: { record in
                forwards.items.withLock { $0.append(record) }
                return true
            })
    }

    static func starts(in directory: URL) -> Int {
        let text = (try? String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0.hasPrefix("start ") }.count
    }

    /// Every child a launch started, first launch first.
    static func children(in directory: URL) -> [pid_t] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("launches.child"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    static func child(in directory: URL) -> pid_t? {
        children(in: directory).first
    }

    /// The test's own cleanup: a child in a session of its own outlives the gateway.
    static func killChildren(in directory: URL) {
        for pid in children(in: directory) { kill(pid, SIGKILL) }
    }

    static func gone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    static func call(_ id: Int, _ tool: String, text: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{"text":"\#(text)"}}}"#
    }

    /// The reply to `id`, skipping notifications.
    static func reply(_ run: GatewayRun, _ id: Int, timeout: TimeInterval = 90) async -> JSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let message = await run.client.next(timeout: max(1, deadline.timeIntervalSinceNow)) else { return nil }
            if message["id"] == .int(id) { return message }
        }
        return nil
    }

    /// Calls `echo` until it is answered (calls during a restart are refused at once).
    static func echoes(_ run: GatewayRun, from first: Int, text: String = "back") async -> JSONValue? {
        for id in first..<(first + 600) {
            run.client.send(Self.call(id, "echo", text: text))
            guard let answer = await Self.reply(run, id) else { return nil }
            if answer["result"] != nil { return answer }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    @Test(.timeLimit(.minutes(5)))
    func aServerThatCrashesIsStartedAgainAndServesTheNextCall() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(core: Self.core(), connections: [.process(Self.launch([], in: directory))])
        #expect(await run.initialize())
        run.client.send(Self.call(2, "crash"))
        let crashed = await Self.reply(run, 2)
        let message = crashed?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("may have run"), "\(String(describing: crashed))")
        let answer = await Self.echoes(run, from: 3)
        #expect(answer?["result"]?["content"]?.arrayValue?.first?["text"] == .string("back"), "\(run.logs.text)")
        #expect(Self.starts(in: directory) == 2)
        let audits = run.audits
        #expect(audits.items.withLock { $0.filter { $0.tool == "crash" } }.map(\.outcome) == [.interrupted(grant: nil)])
        #expect(await run.finish())
    }

    /// Its exit is seen when it is reaped, not when its stdout closes: a
    /// child in a session of its own still holds that open.
    @Test(.timeLimit(.minutes(5)))
    func aServerWhoseChildStillHoldsItsStdoutIsSeenToExit() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(core: Self.core(), connections: [.process(Self.launch(["setsid-child"], in: directory))])
        defer { Self.killChildren(in: directory) }
        #expect(await run.initialize())
        #expect(await eventually { Self.child(in: directory) != nil })
        run.client.send(Self.call(2, "crash"))
        let crashed = await Self.reply(run, 2)
        #expect(crashed?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: crashed))")
        let child = try #require(Self.child(in: directory))
        #expect(Self.gone(child) == false, "the setsid child is outside the group; only the test ends it")
        #expect(await run.finish())
    }

    /// A stop goes to the server's whole group: its child goes with it.
    @Test(.timeLimit(.minutes(5)))
    func aStopReachesTheServersChildToo() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core(), connections: [.process(Self.launch(["child", "ignore-term", "refuse"], in: directory))])
        defer { Self.killChildren(in: directory) }
        #expect(await run.initialize())
        let logs = run.logs
        #expect(await eventually { logs.text.contains("failed to initialize") }, "\(logs.text)")
        let child = try #require(await offThePool { () -> pid_t? in
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let pid = Self.child(in: directory) { return pid }
                usleep(50_000)
            }
            return nil
        })
        #expect(await eventually { Self.gone(child) }, "the child of a stopped server is still running")
        #expect(await eventually { logs.text.contains("MCP server flaky exited") })
        #expect(await run.finish())
    }

    /// Stopped by the runtime (its input bound), it is gone for the core at
    /// once: the next call is refused without being forwarded, and its later
    /// exit is not reported a second time.
    @Test(.timeLimit(.minutes(5)))
    func aServerTheRuntimeStopsIsGoneAtOnceAndExitsOnce() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let forwards = ForwardRecords()
        let run = GatewayRun(
            core: Self.core(forwards: forwards),
            connections: [.process(Self.launch(["deaf", "ignore-term", "child"], in: directory))],
            writeBufferBytes: 256 << 10)
        defer { Self.killChildren(in: directory) }
        #expect(await run.initialize())
        // Listed, it stops reading. The first line is then taken whole and
        // blocks on the full pipe; the second passes the bound.
        run.client.send(#"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#)
        #expect(await Self.reply(run, 10)?["result"] != nil)
        let pad = String(repeating: "p", count: 4 << 20)
        run.client.send(Self.call(2, "echo", text: pad))
        run.client.send(Self.call(3, "echo", text: pad))
        run.client.send(Self.call(4, "echo", text: "after"))
        let stopped = await Self.reply(run, 3)
        #expect(stopped?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: stopped))")
        let refused = await Self.reply(run, 4)
        let message = refused?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("rv is restarting it"), "\(message)")
        #expect(forwards.items.withLock { $0.count } == 2)
        let logs = run.logs
        #expect(await eventually { logs.text.contains("MCP server flaky is back") }, "\(logs.text)")
        #expect(logs.lines.withLock { $0 }.filter { $0.contains("MCP server flaky exited") }.count == 1, "\(logs.text)")
        #expect(await run.finish())
    }

    /// A call that times out is followed by a ping; a server that answers
    /// neither is stopped and started again.
    @Test(.timeLimit(.minutes(5)))
    func aHungServerIsStoppedAndStartedAgain() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(core: Self.core(callTimeout: 1), connections: [.process(Self.launch([], in: directory))])
        #expect(await run.initialize())
        run.client.send(Self.call(2, "hang"))
        let timedOut = await Self.reply(run, 2)
        #expect(timedOut?["error"]?["message"]?.stringValue?.contains("within 1 s") == true, "\(String(describing: timedOut))")
        let logs = run.logs
        #expect(await eventually(120) { logs.text.contains("did not answer a ping") }, "\(logs.text)")
        let answer = await Self.echoes(run, from: 3)
        #expect(answer?["result"] != nil, "\(logs.text)")
        #expect(Self.starts(in: directory) == 2)
        #expect(await run.finish())
    }

    /// A relaunch comes from `relaunch`, and what it adds is scrubbed too.
    @Test(.timeLimit(.minutes(5)))
    func aRelaunchIsPlannedAgainAndItsSecretsAreScrubbed() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = Mutex(0)
        let definition = Self.definition()
        let run = GatewayRun(
            core: Self.core(), connections: [.process(Self.launch([], in: directory))],
            relaunch: { server in
                planned.withLock { $0 += 1 }
                return .success((
                    MCPGatewayCore.Upstream(definition: definition, secretValues: [(name: "TOKEN", value: "fresh-secret-value")]),
                    .process(Self.launch([], in: directory))))
            })
        #expect(await run.initialize())
        run.client.send(Self.call(2, "crash"))
        _ = await Self.reply(run, 2)
        let answer = await Self.echoes(run, from: 3, text: "fresh-secret-value")
        #expect(answer?["result"]?["content"]?.arrayValue?.first?["text"] == .string("[redacted:TOKEN]"))
        #expect(planned.withLock { $0 } == 1)
        #expect(await run.finish())
    }

    /// `gone` counts a zombie as gone: it has exited and waits only to be
    /// reaped, which a container's PID 1 may never do for an orphan.
    @Test(.timeLimit(.minutes(1)))
    func aZombieCountsAsGone() async throws {
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup("exit 0"), nil]
        defer { for pointer in argv { free(pointer) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { arguments in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, "/bin/sh", nil, nil, UnsafeMutablePointer(mutating: arguments.baseAddress!), environment.baseAddress!)
            }
        }
        try #require(status == 0)
        let child = pid
        // Never reaped until the end, so it stays a zombie meanwhile.
        defer {
            var exited: Int32 = 0
            _ = waitpid(child, &exited, 0)
        }
        #expect(await eventually(30) { Self.gone(child) }, "an exited, unreaped child is not gone")
    }
}
