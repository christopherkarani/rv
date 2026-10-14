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

/// `Scripts/mcp-remote-fixture.py` on a loopback port.
final class RemoteFixture: @unchecked Sendable {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Scripts/mcp-remote-fixture.py")

    let process = Process()
    let errors = Pipe()
    private(set) var port = 0

    init(_ arguments: [String] = []) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", Self.script.path] + arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        var line = Data()
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, line.last != 0x0A {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) == 1 else { break }
            line.append(byte)
        }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        port = text.hasPrefix("PORT ") ? Int(text.dropFirst(5)) ?? 0 : 0
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    /// Stops the server and returns its request log. SIGKILL: a child of the
    /// test runner can inherit a mask that blocks SIGTERM.
    func stop() -> String {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        return String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
        _ body: (LineClient) throws -> Void
    ) throws -> RecordedLogs {
        let configuration = MCPConfiguration(defaultDecision: .allow, servers: servers)
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
            approvals: MCPApprovalGate(consumeGrant: { _, _, _ in .none }, request: { _, _, _, _ in nil }))
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
        #expect(client.receive()?["result"]?["serverInfo"]?["name"] == .string("rv"))
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try body(client)
        try client.toGateway.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + 10) == .success)
        return logs
    }

    private func tools(_ client: LineClient) -> [String]? {
        client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        return client.receive()?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
    }

    private func call(_ client: LineClient, id: Int, _ tool: String, _ arguments: String = "{}") -> JSONValue? {
        client.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
        return client.receive()
    }

    private func text(_ reply: JSONValue?) -> String? {
        reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
    }

    @Test func streamableHTTPCarriesSessionVersionAndHeadersAndScrubsTheirSecrets() throws {
        let fixture = try RemoteFixture(["--token", "tok-123"])
        let remote = MCPRemoteServer(
            url: fixture.url("/mcp"), headers: ["Authorization": "Bearer ${secret:API_TOKEN}", "X-Team": "core"])
        _ = try run([MCPServerDefinition(name: "remote", remote: remote, tools: MCPToolPolicy(deny: ["delete_*"]))]) { client in
            #expect(tools(client) == ["echo", "whoami"])
            #expect(text(call(client, id: 3, "echo", #"{"text":"over http"}"#)) == "over http")
            #expect(text(call(client, id: 4, "whoami")) == "authorization=Bearer [redacted:API_TOKEN] team=core")
            #expect(call(client, id: 5, "delete_all")?["result"]?["isError"] == .bool(true))
        }
        let requests = fixture.stop()
        #expect(requests.contains("REQ POST /mcp initialize session=None version=None"), "\(requests)")
        #expect(requests.contains("REQ POST /mcp tools/list session=sess-"), "\(requests)")
        #expect(requests.contains("tools/call session=sess-") && requests.contains("version=2025-06-18"), "\(requests)")
        #expect(requests.range(of: #"DELETE sess-[0-9a-f]+ ok"#, options: .regularExpression) != nil, "\(requests)")
        #expect(requests.contains("delete_all") == false)
    }

    @Test func legacySSEPostsToTheAnnouncedEndpointAndReadsTheStream() throws {
        let fixture = try RemoteFixture(["--token", "tok-123"])
        let remote = MCPRemoteServer(
            url: fixture.url("/sse"), headers: ["Authorization": "Bearer ${secret:API_TOKEN}"], transport: .sse)
        _ = try run([MCPServerDefinition(name: "legacy", remote: remote)]) { client in
            #expect(tools(client) == ["echo", "whoami", "delete_all"])
            #expect(text(call(client, id: 3, "echo", #"{"text":"over sse"}"#)) == "over sse")
        }
        let requests = fixture.stop()
        #expect(requests.contains("REQ GET /sse session="), "\(requests)")
        #expect(requests.contains("REQ POST /sse tools/call session="), "\(requests)")
    }

    @Test func refusedCredentialsAndForeignEndpointsFailTheServerNotTheGateway() throws {
        let fixture = try RemoteFixture(["--token", "tok-123"])
        let logs = try run(
            [
                MCPServerDefinition(name: "locked", remote: MCPRemoteServer(
                    url: fixture.url("/mcp"), headers: ["Authorization": "Bearer ${secret:API_TOKEN}"])),
                MCPServerDefinition(name: "foreign", remote: MCPRemoteServer(
                    url: fixture.url("/sse-foreign"), headers: ["Authorization": "Bearer tok-123"], transport: .sse)),
            ],
            resolver: SecretResolver { _ in .success(SecretValue("wrong-token")!) }
        ) { client in
            #expect(tools(client) == [])
        }
        let requests = fixture.stop()
        #expect(logs.text.contains("locked failed to initialize: MCP server locked refused the credentials (HTTP 401)"), "\(logs.text)")
        #expect(logs.text.contains("MCP server foreign named a message endpoint on another origin; refused"), "\(logs.text)")
        #expect(logs.text.contains("wrong-token") == false)
        #expect(requests.contains("example.invalid") == false)
    }
}
