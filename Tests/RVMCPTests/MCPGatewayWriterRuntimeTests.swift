#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// A stdio MCP server for write stalls; its pid goes to argv[2]. `deaf`:
/// answers initialize, then stops reading its input (for at most 300 s, so
/// a failing run leaves nothing behind). `big`: answers initialize, and each
/// tools/call with a text of `arguments.size` bytes (of `arguments.char`, or
/// "x"). `flood`: answers each tools/call after 20000 list_changed
/// notifications. `silent`: answers nothing.
let writerServer = #"""
    import json, os, sys, time
    mode, pidfile = sys.argv[1], sys.argv[2]
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))
    for line in sys.stdin:
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        if mode == "silent":
            continue
        if method == "initialize":
            result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": mode, "version": "1"}}
        elif method == "notifications/initialized" and mode == "deaf":
            time.sleep(300)
            sys.exit(0)
        elif method == "tools/call" and mode == "big":
            arguments = msg["params"].get("arguments", {})
            size = arguments.get("size", 1)
            result = {"content": [{"type": "text", "text": arguments.get("char", "x") * size}]}
        elif method == "tools/call" and mode == "flood":
            changed = json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}) + "\n"
            sys.stdout.write(changed * 20000)
            result = {"content": []}
        else:
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
    """#

/// True once `condition` holds, polled off the concurrency pool for at most
/// `timeout` seconds: a ceiling, not an expected duration.
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

/// Opens once, by hand; `pass` waits for it.
private final class LogGate: Sendable {
    private let opened = DispatchSemaphore(value: 0)
    let entered = Mutex(false)

    func pass() {
        entered.withLock { $0 = true }
        opened.wait()
        opened.signal()
    }

    func open() { opened.signal() }
}

@Suite("MCPGatewayRuntime writes", .enabled(if: python3Available))
struct MCPGatewayWriterRuntimeTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(writerServer.utf8).write(to: directory.appendingPathComponent("writer.py"))
        return directory
    }

    static func server(_ name: String) -> MCPServerDefinition {
        MCPServerDefinition(name: name, command: "python3", tools: MCPToolPolicy(allow: ["*"]))
    }

    static func launch(_ server: String, mode: String, in directory: URL) -> MCPUpstreamConnection {
        .process(MCPUpstreamLaunch(
            server: server, executable: "/usr/bin/env",
            arguments: [
                "python3", "-u", directory.appendingPathComponent("writer.py").path, mode,
                directory.appendingPathComponent("\(server).pid").path,
            ],
            environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]))
    }

    static func core(_ servers: [MCPServerDefinition]) -> MCPGatewayCore {
        GatewayRun.core(servers, startTimeout: 300)
    }

    static func pid(_ server: String, in directory: URL) -> pid_t? {
        (try? String(contentsOf: directory.appendingPathComponent("\(server).pid"), encoding: .utf8)).flatMap { pid_t($0) }
    }

    /// A call whose argument is far bigger than any pipe buffer.
    static func call(_ id: Int, _ tool: String, padding: Int) -> String {
        let pad = String(repeating: "p", count: padding)
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{"pad":"\#(pad)"}}}"#
    }

    /// An upstream that stops reading holds up only its own writer: another
    /// server's call is still answered, and the client's cancel of the
    /// stuck call is still taken.
    @Test(.timeLimit(.minutes(5)))
    func anUpstreamThatStopsReadingHoldsUpNothingElse() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core([Self.server("deaf"), Self.server("big")]),
            connections: [Self.launch("deaf", mode: "deaf", in: directory), Self.launch("big", mode: "big", in: directory)])
        #expect(await run.initialize())
        run.client.send(Self.call(2, "deaf__wait", padding: 4 << 20))
        run.client.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#)
        run.client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"big__echo","arguments":{"size":10}}}"#)
        let reply = await run.client.next(timeout: 60)
        #expect(reply?["id"] == .int(3), "\(String(describing: reply))")
        #expect(reply?["result"]?["content"]?.arrayValue?.first?["text"] == .string(String(repeating: "x", count: 10)))
        #expect(await run.finish())
    }

    /// Past its bound, an upstream that is not reading is stopped; its calls
    /// fail through the normal exit path, each with one interrupted record.
    @Test(.timeLimit(.minutes(5)))
    func anUpstreamPastItsBoundIsStoppedAndItsCallsFail() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core([Self.server("deaf")]),
            connections: [Self.launch("deaf", mode: "deaf", in: directory)],
            writeBufferBytes: 256 << 10)
        #expect(await run.initialize())
        let logs = run.logs
        #expect(await eventually { Self.pid("deaf", in: directory) != nil })
        run.client.send(Self.call(2, "wait", padding: 4 << 20))
        run.client.send(Self.call(3, "wait", padding: 1 << 10))
        var ids: [Int] = []
        for _ in 0..<2 {
            let reply = await run.client.next(timeout: 90)
            #expect(reply?["error"]?["code"] == .int(-32603), "\(String(describing: reply))")
            if let id = reply?["id"]?.intValue { ids.append(id) }
        }
        #expect(ids.sorted() == [2, 3])
        #expect(logs.text.contains("MCP server deaf is not reading its input"), "\(logs.text)")
        #expect(await eventually { logs.text.contains("MCP server deaf exited") }, "\(logs.text)")
        let audits = run.audits
        #expect(await eventually {
            audits.items.withLock { $0.filter { $0.outcome == .interrupted(grant: nil) }.count == 2 }
        })
        #expect(await run.finish())
    }

    /// A client that takes nothing of what waits for it, for its stall
    /// time, ends the gateway on its own, with one line saying why, and
    /// `run` says so.
    @Test(.timeLimit(.minutes(5)))
    func aClientThatStopsReadingEndsTheGateway() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core([Self.server("big")]),
            connections: [Self.launch("big", mode: "big", in: directory)],
            clientStallSeconds: 1)
        #expect(await run.initialize())
        // Never read: the answer fills the pipe, and nothing more is taken.
        run.client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"size":4194304}}}"#)
        #expect(await run.ended(within: 90))
        #expect(run.ending == .clientNotReading)
        let lines = run.logs.lines.withLock { $0 }.filter { $0.contains("MCP client is not reading") }
        #expect(lines.count == 1, "\(run.logs.text)")
        try? run.client.toGateway.fileHandleForWriting.close()
    }

    /// What an upstream sends counts against its own reader, not against
    /// the client: an answer far past the write bound, queued behind
    /// another (and six times its size once escaped), still goes out.
    @Test(.timeLimit(.minutes(5)))
    func largeAnswersQueuedForASlowClientAllGoOut() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core([Self.server("big")]),
            connections: [Self.launch("big", mode: "big", in: directory)],
            writeBufferBytes: 256 << 10)
        #expect(await run.initialize())
        let size = 1 << 20
        for id in [2, 3] {
            run.client.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo","arguments":{"size":\#(size),"char":"\u007f"}}}"#)
        }
        // Both answers are handed on before the client reads anything.
        let audits = run.audits
        #expect(await eventually {
            audits.items.withLock { $0.filter { if case .ran = $0.outcome { true } else { false } }.count == 2 }
        })
        for id in [2, 3] {
            let reply = await run.client.next(timeout: 90)
            #expect(reply?["id"] == .int(id), "\(String(describing: reply?["error"]))")
            let text = reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
            #expect(text?.unicodeScalars.count == size)
        }
        #expect(run.ending == nil)
        #expect(await run.finish())
    }

    /// An upstream's flood of list_changed reaches a slow client as at most
    /// one waiting notification, and ends nothing.
    @Test(.timeLimit(.minutes(5)))
    func aFloodOfListChangesIsCoalescedForASlowClient() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core([Self.server("flood")]),
            connections: [Self.launch("flood", mode: "flood", in: directory)],
            writeBufferBytes: 256 << 10)
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        // Its answer follows the flood on the same pipe, so once it is handed
        // on every notification before it was handled.
        let audits = run.audits
        #expect(await eventually { audits.items.withLock { $0.contains { if case .ran = $0.outcome { true } else { false } } } })
        var changes = 0
        var answered = false
        while let line = await run.client.next(timeout: 60) {
            if line["id"] == .int(2) {
                answered = true
                break
            }
            if line["method"] == .string("notifications/tools/list_changed") { changes += 1 }
        }
        #expect(answered, "\(run.logs.text)")
        // What the pipe to the client held, and one more.
        #expect(changes >= 1 && changes < 5000, "\(changes)")
        #expect(run.ending == nil)
        #expect(await run.finish())
    }

    /// A non-blocking descriptor that is full is waited on, not given up
    /// on mid-line: every byte arrives, in order.
    @Test(.timeLimit(.minutes(5)))
    func aFullNonBlockingOutputIsWaitedOn() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let (reader, writer) = (fds[0], fds[1])
        #expect(fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK) == 0)
        let bytes = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 % 251) }
        Thread.detachNewThread {
            MCPGatewayRuntime.writeAll(writer, bytes)
            close(writer)
        }
        let received: [UInt8] = await offThePool {
            var all: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                usleep(200)
                let n = read(reader, &chunk, chunk.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                all += chunk[0..<n]
            }
            close(reader)
            return all
        }
        #expect(received.count == bytes.count)
        #expect(received == bytes)
    }

    /// A shutdown gets through while the client's writer is stalled.
    @Test(.timeLimit(.minutes(5)))
    func shutdownGetsThroughWhileTheClientIsNotReading() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = GatewayRun(
            core: Self.core([Self.server("big")]),
            connections: [Self.launch("big", mode: "big", in: directory)])
        #expect(await run.initialize())
        run.client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"size":4194304}}}"#)
        let audits = run.audits
        #expect(await eventually { audits.items.withLock { $0.contains { if case .ran = $0.outcome { true } else { false } } } })
        run.runtime.requestShutdown()
        #expect(await run.ended(within: 90))
        #expect(run.ending == .finished)
        try? run.client.toGateway.fileHandleForWriting.close()
    }

    /// A `log` sink that does not return (a stderr nobody reads) does not
    /// hold up the gateway.
    @Test(.timeLimit(.minutes(5)))
    func aLogSinkThatDoesNotReturnHoldsUpNothing() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = LogGate()
        let silent = Self.server("silent")
        let run = GatewayRun(
            core: GatewayRun.core([silent], startTimeout: 1),
            connections: [Self.launch("silent", mode: "silent", in: directory)],
            log: { _ in gate.pass() })
        #expect(await run.initialize())
        #expect(await eventually { gate.entered.withLock { $0 } })
        run.client.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let pong = await run.client.next(timeout: 60)
        #expect(pong?["id"] == .int(2), "\(String(describing: pong))")
        gate.open()
        #expect(await run.finish())
    }
}
