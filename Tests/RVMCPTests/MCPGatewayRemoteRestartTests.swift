#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import RVMCP

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

/// Remote servers under the restart policy, and what the remote path bounds.
@Suite("MCPGatewayRuntime remote restarts", .enabled(if: python3Available))
struct MCPGatewayRemoteRestartTests {
    static func run(
        _ fixture: RemoteFixture, forwards: ForwardRecords = ForwardRecords(),
        writeBufferBytes: Int = MCPGatewayRuntime.writeBufferBytes
    ) -> GatewayRun {
        let remote = MCPServerDefinition(
            name: "remote", remote: MCPRemoteServer(url: fixture.url("/mcp")), tools: MCPToolPolicy(allow: ["*"]))
        let core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: [remote]), upstreams: [MCPGatewayCore.Upstream(definition: remote)],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced,
            recordForward: { record in
                forwards.items.withLock { $0.append(record) }
                return true
            })
        return GatewayRun(
            core: core, connections: [.remote(MCPRemoteLaunch(server: "remote", url: fixture.url("/mcp")))],
            writeBufferBytes: writeBufferBytes)
    }

    static func call(_ id: Int, text: String = "x") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo","arguments":{"text":"\#(text)"}}}"#
    }

    /// The status of an empty POST to `url`, waited for off the pool.
    static func post(_ url: URL) async -> Int {
        await offThePool {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let status = Mutex(0)
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, response, _ in
                status.withLock { $0 = (response as? HTTPURLResponse)?.statusCode ?? 0 }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 60)
            return status.withLock { $0 }
        }
    }

    static func initializes(_ fixture: RemoteFixture) -> Int {
        fixture.requests().components(separatedBy: "REQ POST /mcp initialize").count - 1
    }

    /// A session the server ends (HTTP 404) is the server going away: the
    /// call on it ends once, saying it may have run, and rv starts a new
    /// session after its delay, which serves the next call.
    @Test(.timeLimit(.minutes(5)))
    func aRemoteThatEndsItsSessionIsConnectedAgain() async throws {
        let fixture = try RemoteFixture()
        let run = Self.run(fixture)
        #expect(await run.initialize())
        // Nothing but the call may meet the ended session: rv's own
        // `notifications/initialized` POST runs beside it, and a 404 on that
        // would end the session first (the call then refused as restarting).
        run.client.send(Self.call(2))
        let served = await MCPGatewayRestartRuntimeTests.reply(run, 2)
        #expect(served?["result"] != nil, "\(String(describing: served))")
        #expect(await eventually { fixture.requests().contains("ACCEPTED notifications/initialized") }, "\(fixture.requests())")
        #expect(await Self.post(fixture.url("/expire-sessions")) == 200)
        run.client.send(Self.call(3))
        let ended = await MCPGatewayRestartRuntimeTests.reply(run, 3)
        #expect(ended?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: ended))")
        let answer = await MCPGatewayRestartRuntimeTests.echoes(run, from: 4)
        #expect(answer?["result"] != nil, "\(run.logs.text)")
        #expect(Self.initializes(fixture) == 2, "\(fixture.requests())")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// A connection that fails under a call is not the server's answer: the
    /// call is recorded as interrupted (it may have run), never as run, and
    /// the server is connected again.
    @Test(.timeLimit(.minutes(5)))
    func aCallWhoseConnectionFailsMayHaveRunAndTheServerComesBack() async throws {
        let fixture = try RemoteFixture(["--reset-calls"])
        let run = Self.run(fixture)
        #expect(await run.initialize())
        run.client.send(Self.call(2))
        let failed = await MCPGatewayRestartRuntimeTests.reply(run, 2)
        #expect(failed?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: failed))")
        let audits = run.audits
        #expect(await eventually { audits.items.withLock { $0.contains { $0.tool == "echo" } } })
        #expect(audits.items.withLock { $0.filter { $0.tool == "echo" }.map(\.outcome) } == [.interrupted(grant: nil)])
        let logs = run.logs
        #expect(await eventually { logs.text.contains("MCP server remote is back") }, "\(logs.text)")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// What a remote has not finished taking counts against its bound until
    /// its POST completes. Past the bound it is stopped, the core hears at
    /// once, and the next call is refused without being forwarded.
    @Test(.timeLimit(.minutes(5)))
    func aRemoteThatTakesNothingIsStoppedPastItsBound() async throws {
        let fixture = try RemoteFixture(["--hang-calls"])
        let forwards = ForwardRecords()
        let run = Self.run(fixture, forwards: forwards, writeBufferBytes: 256 << 10)
        #expect(await run.initialize())
        let pad = String(repeating: "p", count: 200 << 10)
        run.client.send(Self.call(2, text: pad))
        #expect(await eventually { fixture.requests().contains("REQ POST /mcp tools/call") })
        run.client.send(Self.call(3, text: pad))
        run.client.send(Self.call(4))
        for id in [2, 3] {
            let stopped = await MCPGatewayRestartRuntimeTests.reply(run, id)
            #expect(stopped?["error"]?["message"]?.stringValue?.contains("may have run") == true, "\(String(describing: stopped))")
        }
        let refused = await MCPGatewayRestartRuntimeTests.reply(run, 4)
        let message = refused?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("rv is restarting it"), "\(message)")
        #expect(forwards.items.withLock { $0.count } == 2)
        let logs = run.logs
        #expect(await eventually { logs.text.contains("is not reading its input") }, "\(logs.text)")
        #expect(await run.finish())
        _ = await offThePool { fixture.stop() }
    }

    /// Only a request's own POST is closed by its cancel, not a response
    /// rv sent that carries the same id.
    @Test func aCancelClosesOnlyTheRequestItNames() throws {
        let call = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x"}}"#.utf8))
        let response = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8))
        #expect(MCPRemoteUpstream.closes(call, cancelling: .int(7)))
        #expect(MCPRemoteUpstream.closes(call, cancelling: .int(8)) == false)
        #expect(MCPRemoteUpstream.closes(response, cancelling: .int(7)) == false)
    }

    /// A call cancelled while its POST waits on a token refresh is not sent
    /// again with the new token.
    @Test(.timeLimit(.minutes(5)))
    func aCallCancelledDuringItsRefreshIsNotSentAgain() async throws {
        let fixture = try RemoteFixture(["--token", "good-token"])
        let token = Mutex("good-token")
        let refreshing = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let first = Mutex(true)
        let authorizer = MCPRemoteAuthorizer(
            token: { token.withLock { $0 } },
            refresh: { _ in
                if first.withLock({ was in defer { was = false }; return was }) {
                    refreshing.signal()
                    _ = proceed.wait(timeout: .now() + 60)
                }
                token.withLock { $0 = "good-token" }
                return true
            })
        let delivered = RecordedMessages()
        let remote = MCPRemoteUpstream(
            launch: MCPRemoteLaunch(server: "auth", url: fixture.url("/mcp")), authorizer: authorizer,
            deliver: { message in delivered.items.withLock { $0.append(message) } }, exited: {}, log: { _ in })
        remote.start()
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)))
        #expect(await eventually { delivered.items.withLock { $0.contains { $0["id"] == .int(1) } } })
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        token.withLock { $0 = "stale-token" }
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#.utf8)))
        #expect(await offThePool { refreshing.wait(timeout: .now() + 60) } == .success)
        remote.send(try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#.utf8)))
        proceed.signal()
        #expect(await eventually { fixture.requests().contains("REQ POST /mcp notifications/cancelled") }, "\(fixture.requests())")
        // A retry would follow the refresh at once; none comes.
        let sent = await eventually(5) { fixture.requests().contains("REQ POST /mcp tools/call") }
        #expect(sent == false, "\(fixture.requests())")
        await offThePool { remote.stop() }
        _ = await offThePool { fixture.stop() }
    }
}
