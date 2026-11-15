#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVIsolation
import RVPolicy
import Synchronization
import Testing
@testable import RVMCP

@Suite("MCP remote transport")
struct MCPRemoteTransportTests {
    @Test func eventStreamHandlesLineEndingsChunksCommentsAndOpenEvents() {
        var stream = MCPEventStream()
        #expect(stream.feed(Array("\u{FEFF}event: endpoint\r\ndata: /m?s=1\r\n\r\n".utf8))
            == [.init(name: "endpoint", data: "/m?s=1", id: nil)])
        var events: [MCPEventStream.Event] = []
        for byte in Array("data: a\ndata:b\nid: 7\n\n: ping\n\ndata: x\r\rdata: y\r".utf8) { events += stream.feed([byte]) }
        events += stream.feed(Array("\n\ndata: open".utf8))
        #expect(events == [
            .init(name: "message", data: "a\nb", id: "7"),
            .init(name: "message", data: "x", id: "7"),
            .init(name: "message", data: "y", id: "7"),
        ])
        #expect(stream.feed(Array("\n".utf8)).isEmpty)
        #expect(stream.overflowed == false)
    }

    @Test func exchangeBuildsRequestsAndAnswersUnansweredRequests() throws {
        let url = try #require(URL(string: "https://mcp.example.com/mcp"))
        let post = MCPHTTPExchange.request(
            url: url, method: "POST", headers: ["X-Team": "a"], sessionID: "sess-1", protocolVersion: "2025-06-18",
            body: Data("{}".utf8))
        #expect(post.value(forHTTPHeaderField: "Accept") == "application/json, text/event-stream")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(post.value(forHTTPHeaderField: "Mcp-Session-Id") == "sess-1")
        #expect(post.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
        #expect(post.value(forHTTPHeaderField: "X-Team") == "a")
        let get = MCPHTTPExchange.request(url: url, method: "GET", headers: [:], sessionID: nil, protocolVersion: nil, body: nil)
        #expect(get.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(get.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)

        let request = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call"}"#.utf8))
        let failure = try #require(MCPHTTPExchange.failure(for: request, "down"))
        #expect(failure["id"] == .int(4))
        #expect(failure["error"]?["message"] == .string("down"))
        let notification = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(MCPHTTPExchange.failure(for: notification, "down") == nil)

        #expect(MCPHTTPExchange.messages(inJSON: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))?.count == 1)
        #expect(MCPHTTPExchange.messages(inJSON: Data(#"[{"id":1},{"id":2},3]"#.utf8))?.count == 2)
        #expect(MCPHTTPExchange.messages(inJSON: Data("<html>".utf8)) == nil)
        #expect(MCPHTTPExchange.isSessionID("1868a90c-4f6d"))
        #expect(MCPHTTPExchange.isSessionID("a b") == false)
        #expect(MCPHTTPExchange.isSessionID("") == false)
        func origin(_ a: String, _ b: String) -> Bool {
            MCPHTTPExchange.sameOrigin(URL(string: a)!, URL(string: b)!)
        }
        #expect(origin("https://a.example/sse", "https://a.example:443/messages?s=1"))
        #expect(origin("http://127.0.0.1:9/sse", "http://127.0.0.1:9/m"))
        #expect(origin("http://127.0.0.1:9/sse", "http://127.0.0.1:10/m") == false)
        #expect(origin("https://a.example/sse", "http://a.example/m") == false)
        #expect(origin("https://a.example/sse", "https://b.example/m") == false)
        let base = try #require(URL(string: "https://a.example/sse"))
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://a.example/sse", relativeTo: base) == nil)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("/sse", relativeTo: base) == nil)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://a.example/messages", relativeTo: base)?
            .contains("MCP server's URL") == true)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://a.example/sse/", relativeTo: base)?
            .contains("MCP server's URL") == true)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://a.example/sse?x=1", relativeTo: base)?
            .contains("MCP server's URL") == true)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://a.example/%73se", relativeTo: base)?
            .contains("MCP server's URL") == true)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://user:pw@a.example/messages", relativeTo: base)?
            .contains("without credentials") == true)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://a.example/messages?api_key=zzz", relativeTo: base)?
            .contains("secret in its query") == true)
        #expect(MCPRemoteUpstream.messageEndpointRefusal("https://b.example/messages", relativeTo: base) == "on another origin")
    }

    @Test func plannerResolvesHeaderSecretsAndSkipsTheSandboxRuleForRemoteServers() throws {
        let remote = MCPRemoteServer(
            url: try #require(URL(string: "https://mcp.example.com/mcp")),
            headers: ["Authorization": "Bearer ${secret:API_TOKEN}", "X-Team": "core"])
        var configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "r", remote: remote),
            MCPServerDefinition(name: "missing", remote: MCPRemoteServer(url: remote.url, headers: ["A": "${secret:NOPE}"])),
        ])
        configuration.managed = try ManagedPolicy.decode(Data(#"{"version":1,"mcp":{"requireSandbox":true}}"#.utf8)).get()
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "API_TOKEN", source: .hostEnvironment(variable: "UNUSED"), delivery: .environment)
        ])
        func plan(_ name: String, value: String = "tok_remote_1234") -> Result<[(MCPGatewayCore.Upstream, MCPUpstreamConnection)], MCPLaunchError> {
            MCPLaunchPlanner.plan(
                servers: [name], configuration: configuration, secrets: secrets,
                resolver: SecretResolver { _ in .success(SecretValue(value)!) }, baseEnvironment: [:])
        }
        let planned = try plan("r").get()
        #expect(planned[0].1 == .remote(MCPRemoteLaunch(
            server: "r", url: remote.url, headers: ["Authorization": "Bearer tok_remote_1234", "X-Team": "core"])))
        #expect(planned[0].0.secretValues.map(\.name) == ["API_TOKEN"])
        #expect(planned[0].0.secretValues.map(\.value) == ["tok_remote_1234"])
        guard case .failure(let undefined) = plan("missing"), case .failure(let multiline) = plan("r", value: "a\r\nX-Evil: 1")
        else {
            Issue.record("planner accepted an undefined or multi-line header secret")
            return
        }
        #expect(undefined == .secretUndefined(server: "missing", secret: "NOPE"))
        #expect(multiline == .secretUnavailable(server: "r", secret: "API_TOKEN", reason: "not usable as text"))
    }
}

/// The fixture never said which port it listens on. Thrown from `init`, so
/// the test stops there and records what the fixture did instead.
struct RemoteFixtureUnstarted: Error, CustomStringConvertible {
    var description: String
}

/// `Scripts/mcp-remote-fixture.py` on a loopback port.
final class RemoteFixture: @unchecked Sendable {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Scripts/mcp-remote-fixture.py")
    /// A minute, not seconds: the first `python3` on a cold macOS runner
    /// goes through the developer-tools shim, and a suite's fixtures start
    /// together.
    static let startTimeout: TimeInterval = 60

    let process = Process()
    let errors = Pipe()
    let port: Int

    /// Throws `RemoteFixtureUnstarted` when no `PORT n` line arrives within
    /// `startTimeout`: the fixture is killed and its exit state, its stderr
    /// and what it printed instead are in the error.
    init(_ arguments: [String] = []) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", Self.script.path] + arguments
        process.standardOutput = output
        process.standardError = errors
        let started = Date()
        try process.run()
        var line = Data()
        var readError: Int32 = 0
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = started.addingTimeInterval(Self.startTimeout)
        while Date() < deadline, line.last != 0x0A {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            guard n == 1 else {
                readError = n < 0 ? errno : 0
                break
            }
            line.append(byte)
        }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Without a port every request would go to port 0 and each test
        // would fail on its own expectations, saying nothing of why: the
        // error below stops it instead.
        if text.hasPrefix("PORT "), let port = Int(text.dropFirst(5)), port > 0 {
            self.port = port
            let waited = Int(Date().timeIntervalSince(started))
            if waited >= 5 { print("mcp-remote-fixture took \(waited) s to report its port") }
            return
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        // Only a fixture still running is signalled: once it has been
        // reaped its pid may belong to another process.
        let running = process.isRunning
        if running { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let state = running
            ? "still running (killed now)"
            : "exited (\(process.terminationReason == .exit ? "status" : "signal") \(process.terminationStatus))"
        let stderr = Self.available(errors.fileHandleForReading.fileDescriptor)
        throw RemoteFixtureUnstarted(description: """
            remote fixture printed no PORT line in \(elapsed) s: \(state); \
            stdout \(String(reflecting: text))\(readError == 0 ? "" : ", read errno \(readError)"); \
            stderr \(String(reflecting: stderr))
            """)
    }

    /// What `fd` holds now, without waiting for its end: a child the fixture
    /// left could still hold the write end open.
    private static func available(_ fd: Int32) -> String {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            data.append(contentsOf: chunk[0..<n])
        }
        return String(decoding: data, as: UTF8.self)
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private let logged = Mutex(Data())

    /// The request log so far, the server left running.
    func requests() -> String {
        let fd = errors.fileHandleForReading.fileDescriptor
        return logged.withLock { data in
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 0) > 0, poller.revents & Int16(POLLIN) != 0 else { break }
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { break }
                data.append(contentsOf: chunk[0..<n])
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Stops the server and returns its whole request log. SIGKILL: a child
    /// of the test runner can inherit a mask that blocks SIGTERM.
    func stop() -> String {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let rest = errors.fileHandleForReading.readDataToEndOfFile()
        return logged.withLock { String(decoding: $0 + rest, as: UTF8.self) }
    }
}

final class RecordedLogs: Sendable {
    let lines = Mutex<[String]>([])
    var text: String { lines.withLock { $0.joined(separator: "\n") } }
}

@Suite("MCP remote upstream through the runtime", .enabled(if: python3Available))
struct MCPRemoteRuntimeTests {
    private func run(
        _ servers: [MCPServerDefinition], resolver: SecretResolver = SecretResolver { _ in .success(SecretValue("tok-123")!) },
        _ body: (LineClient) async throws -> Void
    ) async throws -> RecordedLogs {
        let configuration = MCPConfiguration(servers: servers)
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "API_TOKEN", source: .hostEnvironment(variable: "UNUSED"), delivery: .environment)
        ])
        let planned = try MCPLaunchPlanner.plan(
            servers: servers.map(\.name), configuration: configuration, secrets: secrets, resolver: resolver,
            baseEnvironment: [:]
        ).get()
        let client = LineClient()
        let logs = RecordedLogs()
        let core = MCPGatewayCore(
            configuration: configuration, upstreams: planned.map { $0.0 },
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        let runtime = MCPGatewayRuntime(
            core: core, connections: planned.map { $0.1 },
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { line in logs.lines.withLock { $0.append(line) } })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        #expect(await client.next()?["result"]?["serverInfo"]?["name"] == .string("rv"))
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try await body(client)
        try client.toGateway.fileHandleForWriting.close()
        #expect(await offThePool { done.wait(timeout: .now() + 10) } == .success)
        // What the gateway said of its upstreams, where a test then fails.
        if logs.text.isEmpty == false { print("gateway log for \(servers.map(\.name)): \(logs.text)") }
        return logs
    }

    private func tools(_ client: LineClient) async -> [String]? {
        client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        return await client.next()?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
    }

    private func call(_ client: LineClient, id: Int, _ tool: String, _ arguments: String = "{}") async -> JSONValue? {
        client.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
        return await client.next()
    }

    private func text(_ reply: JSONValue?) -> String? {
        reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
    }

    @Test func streamableHTTPCarriesSessionVersionAndHeadersAndScrubsTheirSecrets() async throws {
        let fixture = try RemoteFixture(["--token", "tok-123"])
        let remote = MCPRemoteServer(
            url: fixture.url("/mcp"), headers: ["Authorization": "Bearer ${secret:API_TOKEN}", "X-Team": "core"])
        _ = try await run([MCPServerDefinition(name: "remote", remote: remote, tools: MCPToolPolicy(allow: ["*"], deny: ["delete_*"]))]) { client in
            #expect(await tools(client) == ["echo", "whoami"])
            #expect(text(await call(client, id: 3, "echo", #"{"text":"over http"}"#)) == "over http")
            #expect(text(await call(client, id: 4, "whoami")) == "authorization=Bearer [redacted:API_TOKEN] team=core")
            #expect(await call(client, id: 5, "delete_all")?["result"]?["isError"] == .bool(true))
        }
        let requests = await offThePool { fixture.stop() }
        #expect(requests.contains("REQ POST /mcp initialize session=None version=None"), "\(requests)")
        #expect(requests.contains("REQ POST /mcp tools/list session=sess-"), "\(requests)")
        #expect(requests.contains("tools/call session=sess-") && requests.contains("version=2025-06-18"), "\(requests)")
        #expect(requests.range(of: #"DELETE sess-[0-9a-f]+ ok"#, options: .regularExpression) != nil, "\(requests)")
        #expect(requests.contains("delete_all") == false)
    }

    @Test func legacySSEPostsToTheAnnouncedEndpointAndReadsTheStream() async throws {
        let fixture = try RemoteFixture(["--token", "tok-123"])
        let remote = MCPRemoteServer(
            url: fixture.url("/sse"), headers: ["Authorization": "Bearer ${secret:API_TOKEN}"], transport: .sse)
        _ = try await run([MCPServerDefinition(name: "legacy", remote: remote, tools: MCPToolPolicy(allow: ["*"]))]) { client in
            #expect(await tools(client) == ["echo", "whoami", "delete_all"])
            #expect(text(await call(client, id: 3, "echo", #"{"text":"over sse"}"#)) == "over sse")
        }
        let requests = await offThePool { fixture.stop() }
        #expect(requests.contains("REQ GET /sse session="), "\(requests)")
        #expect(requests.contains("REQ POST /sse tools/call session="), "\(requests)")
    }

    @Test func refusedCredentialsAndForeignEndpointsFailTheServerNotTheGateway() async throws {
        let fixture = try RemoteFixture(["--token", "tok-123"])
        let logs = try await run(
            [
                MCPServerDefinition(name: "locked", remote: MCPRemoteServer(
                    url: fixture.url("/mcp"), headers: ["Authorization": "Bearer ${secret:API_TOKEN}"])),
                MCPServerDefinition(name: "foreign", remote: MCPRemoteServer(
                    url: fixture.url("/sse-foreign"), headers: ["Authorization": "Bearer tok-123"], transport: .sse)),
            ],
            resolver: SecretResolver { _ in .success(SecretValue("wrong-token")!) }
        ) { client in
            #expect(await tools(client) == [])
        }
        let requests = await offThePool { fixture.stop() }
        #expect(logs.text.contains("locked failed to initialize: MCP server locked refused the credentials (HTTP 401)"), "\(logs.text)")
        #expect(logs.text.contains("MCP server foreign named a message endpoint on another origin; refused"), "\(logs.text)")
        #expect(logs.text.contains("wrong-token") == false)
        #expect(requests.contains("example.invalid") == false)
    }
}
