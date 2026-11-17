#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import Synchronization
import Testing
@testable import RVMCP

/// A stdio server that can be made to go away. Every start appends
/// `start <pid>` to argv[1]. Tools: `echo` (answers `text`), `crash` (exits
/// at once, unanswered), `hang` (never answers, nor any ping after it).
/// Options after argv[2]: `child` forks a child in its group, `setsid-child`
/// one in a session of its own (both hold its stdout and write their pid to
/// argv[1].child), `ignore-term` ignores SIGTERM, `deaf` never reads after
/// the listing, `refuse` answers initialize with an error. `late-line`: the
/// first launch's child, once argv[1].go exists, writes a list_changed and
/// then a line that is not JSON to the stdout it holds.
let restartingServer = #"""
    import json, os, signal, sys, time
    launches, options = sys.argv[1], sys.argv[2:]
    with open(launches, "a") as f:
        f.write("start %d\n" % os.getpid())
    with open(launches) as f:
        first = f.read().count("start ") == 1
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
            if "late-line" in options and first:
                while not os.path.exists(launches + ".go"):
                    time.sleep(0.05)
                os.write(1, b'{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\nlate, not json\n')
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

    static func launch(_ options: [String], in directory: URL, server: String = "flaky") -> MCPUpstreamLaunch {
        MCPUpstreamLaunch(
            server: server, executable: "/usr/bin/env",
            arguments: ["python3", "-u", directory.appendingPathComponent("server.py").path,
                        directory.appendingPathComponent("launches").path] + options,
            environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"])
    }

    static func definition(
        callTimeout: Int = 300, startTimeout: Int = MCPServerDefinition.defaultStartTimeoutSeconds, server name: String = "flaky"
    ) -> MCPServerDefinition {
        var server = MCPServerDefinition(name: name, command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        server.callTimeoutSeconds = callTimeout
        server.startTimeoutSeconds = startTimeout
        return server
    }

    static func core(
        callTimeout: Int = 300, startTimeout: Int = MCPServerDefinition.defaultStartTimeoutSeconds,
        forwards: ForwardRecords = ForwardRecords(), server name: String = "flaky"
    ) -> MCPGatewayCore {
        let server = definition(callTimeout: callTimeout, startTimeout: startTimeout, server: name)
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

    /// No such process, or a zombie: exited and waiting only to be reaped,
    /// which `kill(pid, 0)` still finds and a container's PID 1 may never
    /// do for an orphan.
    static func gone(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return errno == ESRCH }
        return isZombie(pid)
    }

    /// Read without a shell: `sysctl` `KERN_PROC_PID` on macOS
    /// (`proc_pidinfo` answers nothing for a zombie), `/proc/<pid>/stat`'s
    /// state (the first field after the command's closing parenthesis) on
    /// Linux.
    static func isZombie(_ pid: pid_t) -> Bool {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &length, nil, 0) == 0, length > 0 else { return false }
        return Int32(info.kp_proc.p_stat) == SZOMB
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
            let close = stat.lastIndex(of: ")")
        else { return false }
        return stat[stat.index(after: close)...].split(separator: " ").first == "Z"
        #endif
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
        defer { run.stopNow() }
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
        defer { run.stopNow() }
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
        defer { run.stopNow() }
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
        defer { run.stopNow() }
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
        // The old launch was reaped before it was planned again; a second
        // report would come at most the exit gate's 1 s grace after that.
        try await Task.sleep(nanoseconds: 3_000_000_000)
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
        defer { run.stopNow() }
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
        defer { run.stopNow() }
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

    /// `relaunch` for the tests below: counted, then the same launch again.
    static func counting(
        _ planned: PlanCount, in directory: URL, server: String = "flaky"
    ) -> MCPGatewayRuntime.Relaunch {
        let definition = Self.definition(server: server)
        return { _ in
            planned.value.withLock { $0 += 1 }
            return .success((MCPGatewayCore.Upstream(definition: definition), .process(Self.launch([], in: directory, server: server))))
        }
    }

    /// The listing, then two 4 MiB calls: a `deaf` server stops reading, and
    /// with a 256 KiB bound the runtime stops it (`aServerTheRuntimeStops…`).
    static func overflow(_ run: GatewayRun) async -> JSONValue? {
        run.client.send(#"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#)
        guard await Self.reply(run, 10)?["result"] != nil else { return nil }
        let pad = String(repeating: "p", count: 4 << 20)
        run.client.send(Self.call(2, "echo", text: pad))
        run.client.send(Self.call(3, "echo", text: pad))
        return await Self.reply(run, 3)
    }

    /// The runtime runs one launch of a server at a time: a restart asked
    /// for while it runs is refused and logged, and nothing is planned.
    @Test(.timeLimit(.minutes(5)))
    func aRestartOfARunningServerIsRefused() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = PlanCount()
        let run = GatewayRun(
            core: Self.core(), connections: [.process(Self.launch([], in: directory))],
            relaunch: Self.counting(planned, in: directory))
        defer { run.stopNow() }
        #expect(await run.initialize())
        await offThePool { run.runtime.performOnQueue([.restartUpstream(server: "flaky", launch: -1)]) }
        let logs = run.logs
        try #require(
            await eventually(30) { logs.text.contains("not starting MCP server flaky again: it is running") }, "\(logs.text)")
        let answer = await Self.echoes(run, from: 2)
        #expect(answer?["result"] != nil, "\(logs.text)")
        #expect(planned.value.withLock { $0 } == 0)
        #expect(Self.starts(in: directory) == 1)
        #expect(await run.finish())
    }

    /// A restart asked for while one is being planned is refused and
    /// logged: one plan runs, and one launch comes of it.
    @Test(.timeLimit(.minutes(5)))
    func aRestartWhileOneIsBeingPlannedIsRefused() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = PlanCount()
        let release = DispatchSemaphore(value: 0)
        let plan = Self.counting(planned, in: directory)
        let run = GatewayRun(
            core: Self.core(), connections: [.process(Self.launch([], in: directory))],
            relaunch: { server in
                let result = plan(server)
                _ = release.wait(timeout: .now() + 120)
                return result
            })
        defer { run.stopNow() }
        defer {
            release.signal()
            release.signal()
        }
        #expect(await run.initialize())
        run.client.send(Self.call(2, "crash"))
        _ = await Self.reply(run, 2)
        try #require(await eventually { planned.value.withLock { $0 } == 1 })
        await offThePool { run.runtime.performOnQueue([.restartUpstream(server: "flaky", launch: -1)]) }
        let logs = run.logs
        try #require(
            await eventually(30) { logs.text.contains("not starting MCP server flaky again: it is already being started") },
            "\(logs.text)")
        release.signal()
        let answer = await Self.echoes(run, from: 3)
        #expect(answer?["result"] != nil, "\(logs.text)")
        #expect(planned.value.withLock { $0 } == 1)
        #expect(Self.starts(in: directory) == 2)
        #expect(await run.finish())
    }

    /// Once serve is stopping, no relaunch is planned: a restart still
    /// waiting for its last process (SIGTERM ignored, SIGKILL an hour away)
    /// plans nothing once serve's own stop reaps it.
    @Test(.timeLimit(.minutes(5)))
    func aRestartWaitingWhenServeStopsPlansNothing() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = PlanCount()
        let run = GatewayRun(
            core: Self.core(), connections: [.process(Self.launch(["deaf", "ignore-term"], in: directory))],
            writeBufferBytes: 256 << 10, relaunch: Self.counting(planned, in: directory), stopGrace: 3600)
        defer { run.stopNow() }
        #expect(await run.initialize())
        let stopped = await Self.overflow(run)
        #expect(stopped?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: stopped))")
        // One restart is under way (the core's or this one): the other is refused.
        await offThePool { run.runtime.performOnQueue([.restartUpstream(server: "flaky", launch: -1)]) }
        let logs = run.logs
        try #require(
            await eventually(30) { logs.text.contains("not starting MCP server flaky again: it is already being started") },
            "\(logs.text)")
        #expect(await run.finish())
        // The restart saw the reap within 10 ms; it had two seconds to plan.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(planned.value.withLock { $0 } == 0)
        #expect(Self.starts(in: directory) == 1)
    }

    /// Planning under way when serve stops is abandoned once it returns:
    /// nothing is started, and the proxy it started is stopped and untracked.
    @Test(.timeLimit(.minutes(5)))
    func aRelaunchPlannedWhileServeStopsStartsNothingAndStopsItsProxy() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = "flaky-proxied-\(UUID().uuidString.prefix(8))"
        let planning = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let started = Mutex<(proxy: EgressProxy, port: Int)?>(nil)
        defer { started.withLock { $0?.proxy.stop() } }
        let definition = Self.definition(server: server)
        let run = GatewayRun(
            core: Self.core(server: server), connections: [.process(Self.launch([], in: directory, server: server))],
            relaunch: { name in
                planning.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 120)
                // As `MCPSandbox.apply` plans a server with `sandbox.hosts`.
                let credential = MCPSandbox.proxyCredential()
                let proxy = MCPSandboxProxyTests.proxy(credential: credential)
                guard case .success(let port) = proxy.start() else { return .failure(.sandbox("no proxy")) }
                MCPSandbox.track(proxy, server: name)
                started.withLock { $0 = (proxy, port) }
                var launch = Self.launch([], in: directory, server: name)
                launch.environment = MCPSandbox.proxyEnvironment(launch.environment, port: port, credential: credential)
                return .success((MCPGatewayCore.Upstream(definition: definition), .process(launch)))
            })
        defer { run.stopNow() }
        defer { release.signal() }
        #expect(await run.initialize())
        run.client.send(Self.call(2, "crash"))
        _ = await Self.reply(run, 2)
        try #require(await eventually { planning.withLock { $0 } })
        #expect(await run.finish())
        release.signal()
        try #require(await eventually { started.withLock { $0 } != nil })
        let port = try #require(started.withLock { $0?.port })
        #expect(await eventually(30) { MCPSandboxProxyTests.accepts(port) == false }, "the abandoned plan's proxy still runs")
        #expect(MCPSandbox.proxies.withLock { $0.contains { $0.server == server } } == false)
        #expect(Self.starts(in: directory) == 1)
    }

    /// A restart whose last process is not reaped within its wait plans
    /// nothing: it says why, and counts as one more time the server went away.
    @Test(.timeLimit(.minutes(5)))
    func aRestartWhoseLastProcessIsNotReapedInTimePlansNothing() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = PlanCount()
        let run = GatewayRun(
            core: Self.core(), connections: [.process(Self.launch(["deaf", "ignore-term"], in: directory))],
            writeBufferBytes: 256 << 10, relaunch: Self.counting(planned, in: directory), stopGrace: 3600,
            restartWait: 1)
        defer { run.stopNow() }
        #expect(await run.initialize())
        let stopped = await Self.overflow(run)
        #expect(stopped?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: stopped))")
        let logs = run.logs
        #expect(
            await eventually { logs.text.contains("could not start MCP server flaky again: its last process did not exit") },
            "\(logs.text)")
        #expect(planned.value.withLock { $0 } == 0)
        #expect(Self.starts(in: directory) == 1)
        #expect(await run.finish())
    }

    /// rv's own wait for the stopped launch to be reaped is not the new
    /// launch's start time: a server whose SIGKILL comes 15 s after its
    /// stop still has its whole 10 s `startTimeoutSeconds` once it is
    /// reaped, and comes back on the first try. (10 s, so the first
    /// launch's python has ample time to start on a starved runner.)
    @Test(.timeLimit(.minutes(5)))
    func aRelaunchKeepsItsWholeStartTimeoutPastTheWaitForItsLastProcess() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = PlanCount()
        let run = GatewayRun(
            core: Self.core(startTimeout: 10), connections: [.process(Self.launch(["deaf", "ignore-term"], in: directory))],
            writeBufferBytes: 256 << 10, relaunch: Self.counting(planned, in: directory), stopGrace: 15)
        defer { run.stopNow() }
        #expect(await run.initialize())
        let stopped = await Self.overflow(run)
        #expect(stopped?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: stopped))")
        let logs = run.logs
        let answer = await Self.echoes(run, from: 4)
        #expect(answer?["result"] != nil, "\(logs.text)")
        #expect(logs.text.contains("did not start again") == false, "\(logs.text)")
        #expect(planned.value.withLock { $0 } == 1, "\(logs.text)")
        #expect(Self.starts(in: directory) == 2)
        #expect(await run.finish())
    }

    /// A plan that never returns is not waited on for good: its launch runs
    /// out of its start timeout, every later restart is refused while the
    /// plan still runs and counts as one more time the server went away,
    /// and past the restart cap the server fails for the session.
    @Test(.timeLimit(.minutes(5)))
    func aPlanThatNeverReturnsEndsWithTheServerFailed() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = PlanCount()
        let release = DispatchSemaphore(value: 0)
        let run = GatewayRun(
            core: Self.core(startTimeout: 10), connections: [.process(Self.launch([], in: directory))],
            relaunch: { _ in
                planned.value.withLock { $0 += 1 }
                _ = release.wait(timeout: .now() + 240)
                return .failure(.unknownServer("flaky"))
            })
        defer { run.stopNow() }
        defer { release.signal() }
        #expect(await run.initialize())
        run.client.send(Self.call(2, "crash"))
        _ = await Self.reply(run, 2)
        let logs = run.logs
        #expect(await eventually(120) { logs.text.contains("so rv stopped restarting it") }, "\(logs.text)")
        #expect(logs.text.contains("not starting MCP server flaky again: it is already being started"), "\(logs.text)")
        #expect(planned.value.withLock { $0 } == 1)
        run.client.send(Self.call(3, "echo"))
        let refused = await Self.reply(run, 3)
        #expect(refused?["error"]?["message"]?.stringValue?.contains("rv stopped restarting it") == true, "\(String(describing: refused))")
        release.signal()
        #expect(await run.finish())
    }

    /// A plan that returns just past its launch's start timeout, before
    /// the tick that would expire it, starts nothing: the launch is no
    /// longer awaited, it counts once, and the next try brings the server
    /// back with one start.
    @Test(.timeLimit(.minutes(5)))
    func aPlanReturningPastItsStartTimeoutStartsNothing() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = PlanCount()
        let plan = Self.counting(planned, in: directory)
        let run = GatewayRun(
            core: Self.core(startTimeout: 10), connections: [.process(Self.launch([], in: directory))],
            relaunch: { server in
                let late = planned.value.withLock { $0 } == 0
                // The deadline is set just before planning starts.
                if late { usleep(10_200_000) }
                return plan(server)
            })
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(Self.call(2, "crash"))
        _ = await Self.reply(run, 2)
        let logs = run.logs
        let answer = await Self.echoes(run, from: 3)
        #expect(answer?["result"] != nil, "\(logs.text)")
        #expect(planned.value.withLock { $0 } == 2, "\(logs.text)")
        #expect(Self.starts(in: directory) == 2, "\(logs.text)")
        #expect(logs.text.contains("it is running") == false, "\(logs.text)")
        #expect(logs.text.components(separatedBy: "did not start again").count == 2, "\(logs.text)")
        #expect(await run.finish())
    }

    /// A plan that succeeds but whose launch cannot be spawned ends what
    /// the plan started at once: its cage's proxy is stopped and untracked.
    @Test(.timeLimit(.minutes(5)))
    func aPlannedLaunchThatCannotBeSpawnedStopsItsProxy() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = "flaky-unspawnable-\(UUID().uuidString.prefix(8))"
        let started = Mutex<(proxy: EgressProxy, port: Int)?>(nil)
        defer { started.withLock { $0?.proxy.stop() } }
        let definition = Self.definition(server: server)
        let run = GatewayRun(
            core: Self.core(server: server), connections: [.process(Self.launch([], in: directory, server: server))],
            relaunch: { name in
                // Only the first plan starts a proxy; later ones fail.
                guard started.withLock({ $0 }) == nil else { return .failure(.unknownServer(name)) }
                let credential = MCPSandbox.proxyCredential()
                let proxy = MCPSandboxProxyTests.proxy(credential: credential)
                guard case .success(let port) = proxy.start() else { return .failure(.sandbox("no proxy")) }
                MCPSandbox.track(proxy, server: name)
                started.withLock { $0 = (proxy, port) }
                var launch = Self.launch([], in: directory, server: name)
                launch.executable = directory.appendingPathComponent("no-such-executable").path
                launch.environment = MCPSandbox.proxyEnvironment(launch.environment, port: port, credential: credential)
                return .success((MCPGatewayCore.Upstream(definition: definition), .process(launch)))
            })
        defer { run.stopNow() }
        #expect(await run.initialize())
        run.client.send(Self.call(2, "crash"))
        _ = await Self.reply(run, 2)
        let logs = run.logs
        try #require(await eventually(30) { logs.text.contains("could not start MCP server \(server)") }, "\(logs.text)")
        let port = try #require(started.withLock { $0?.port })
        #expect(await eventually(5) { MCPSandboxProxyTests.accepts(port) == false }, "the unspawned launch's proxy still runs")
        #expect(MCPSandbox.proxies.withLock { $0.contains { $0.server == server } } == false)
        #expect(await run.finish())
    }

    /// What an old launch writes after it was replaced reaches nobody: its
    /// child (in a session of its own) still holds its stdout and writes a
    /// list_changed after the relaunch, which the client never gets.
    @Test(.timeLimit(.minutes(5)))
    func linesFromAnOldLaunchAfterARelaunchAreIgnored() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core(), connections: [.process(Self.launch(["setsid-child", "late-line"], in: directory))])
        defer { run.stopNow() }
        defer { Self.killChildren(in: directory) }
        #expect(await run.initialize())
        #expect(await eventually { Self.child(in: directory) != nil })
        run.client.send(Self.call(2, "crash"))
        _ = await Self.reply(run, 2)
        let logs = run.logs
        try #require(await Self.echoes(run, from: 3)?["result"] != nil, "\(logs.text)")
        try Data().write(to: directory.appendingPathComponent("launches.go"))
        // The old reader reads in order: once the second line is logged,
        // the first is already on the gateway queue.
        try #require(await eventually { logs.text.contains("MCP server flaky wrote a line that is not JSON") }, "\(logs.text)")
        run.client.send(Self.call(1000, "echo", text: "after"))
        var seen: [JSONValue] = []
        while let message = await run.client.next(timeout: 90) {
            seen.append(message)
            if message["id"] == .int(1000) { break }
        }
        #expect(seen.last?["id"] == .int(1000), "\(seen)")
        #expect(seen.contains { $0["method"]?.stringValue == "notifications/tools/list_changed" } == false, "\(seen)")
        #expect(await run.finish())
    }
}

/// How many times a test's `relaunch` planned.
final class PlanCount: Sendable {
    let value = Mutex(0)
}

extension GatewayRun {
    /// Ends `run` now and kills its servers at once: a test's cleanup on
    /// every path, a failed expectation included. After `finish` it does
    /// nothing.
    func stopNow() {
        runtime.requestShutdown()
        runtime.requestShutdown()
    }
}

/// The wait a restart makes for its server's last launches to be reaped.
@Suite("MCPGatewayRuntime restart wait")
struct MCPLaunchEndTests {
    static func later(_ seconds: Double) -> SuspendingClock.Instant {
        SuspendingClock.now.advanced(by: .seconds(seconds))
    }

    @Test func theWaitIsOverOnceEveryLaunchHasEnded() {
        let ends = [MCPLaunchEnd(), MCPLaunchEnd()]
        ends.forEach { $0.end() }
        #expect(MCPLaunchEnd.wait(for: ends, until: Self.later(60), abandoned: { false }) == .ended)
        #expect(MCPLaunchEnd.wait(for: [], until: Self.later(60), abandoned: { false }) == .ended)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLaunchThatEndsDuringTheWaitEndsIt() {
        let end = MCPLaunchEnd()
        Thread.detachNewThread {
            usleep(50_000)
            end.end()
        }
        #expect(MCPLaunchEnd.wait(for: [end], until: Self.later(50), abandoned: { false }) == .ended)
    }

    /// Measured on the monotonic clock: a wall-clock step neither cuts it
    /// short nor stretches it.
    @Test func theWaitRunsOutOnTheMonotonicClock() {
        let start = SuspendingClock.now
        let deadline = start.advanced(by: .milliseconds(100))
        #expect(MCPLaunchEnd.wait(for: [MCPLaunchEnd()], until: deadline, abandoned: { false }) == .timedOut)
        #expect(SuspendingClock.now >= deadline)
    }

    /// Once serve is stopping, the wait is over without planning anything,
    /// whether or not its launches have ended.
    @Test func theWaitIsAbandonedOnceServeStops() {
        let ended = MCPLaunchEnd()
        ended.end()
        #expect(MCPLaunchEnd.wait(for: [MCPLaunchEnd()], until: Self.later(60), abandoned: { true }) == .abandoned)
        #expect(MCPLaunchEnd.wait(for: [ended], until: Self.later(60), abandoned: { true }) == .abandoned)
    }
}
