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

/// A real stdio MCP server: newline JSON-RPC, three tools. `whoami` echoes
/// the FIXTURE_TOKEN it was given so tests can prove scrubbing.
let fixtureServer = #"""
    import json, os, sys
    TOOLS = [
        {"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
        {"name": "whoami", "description": "Show the token", "inputSchema": {"type": "object"}},
        {"name": "delete_all", "description": "Dangerous", "inputSchema": {"type": "object"}},
    ]
    for line in sys.stdin:
        msg = json.loads(line)
        if "id" not in msg:
            continue
        method, mid = msg.get("method"), msg["id"]
        if method == "initialize":
            result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            name, args = msg["params"]["name"], msg["params"].get("arguments", {})
            if name == "echo":
                text = args.get("text", "")
            elif name == "whoami":
                text = "token is " + os.environ.get("FIXTURE_TOKEN", "missing")
            else:
                text = "deleted everything"
            result = {"content": [{"type": "text", "text": text}]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
    """#

let python3Available: Bool = {
    ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].contains {
        FileManager.default.isExecutableFile(atPath: $0)
    }
}()

final class LineClient: @unchecked Sendable {
    let toGateway = Pipe()
    let fromGateway = Pipe()
    private var buffer = Data()

    func send(_ text: String) {
        toGateway.fileHandleForWriting.write(Data((text + "\n").utf8))
    }

    /// Next line from the gateway, or nil after `timeout`.
    func receive(timeout: TimeInterval = 15) -> JSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        let fd = fromGateway.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return try? JSONValue.parse(Data(line))
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return nil
    }
}

final class RecordedAudits: Sendable {
    let items = Mutex<[MCPCallRecord]>([])
}

@Suite("MCPGatewayRuntime", .enabled(if: python3Available))
struct MCPGatewayRuntimeTests {
    @Test func realUpstreamThroughTheRealRuntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        try Data(fixtureServer.utf8).write(to: script)

        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "fixture", command: "python3", args: ["-u", script.path],
                secrets: ["FIXTURE_TOKEN": "FIXTURE_SECRET"],
                tools: MCPToolPolicy(allow: ["*"], deny: ["delete_*"]),
                sandbox: MCPSandboxPolicy(network: false))
        ])
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "FIXTURE_SECRET", source: .hostEnvironment(variable: "UNUSED"), delivery: .environment)
        ])
        let resolver = SecretResolver { _ in .success(SecretValue("tok_live_9f8e7d6c5b4a")!) }
        var base = ProcessInfo.processInfo.environment
        base["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:" + (base["PATH"] ?? "")
        let planned = try MCPLaunchPlanner.plan(
            servers: ["fixture"], configuration: configuration, secrets: secrets, resolver: resolver,
            baseEnvironment: base
        ).get()
        #expect(planned[0].1.process?.environment["FIXTURE_TOKEN"] == "tok_live_9f8e7d6c5b4a")

        let client = LineClient()
        let audits = RecordedAudits()
        let core = MCPGatewayCore(
            configuration: configuration, upstreams: planned.map { $0.0 },
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _ in .none }, request: { _, _, _, _ in nil }))
        let runtime = MCPGatewayRuntime(
            core: core, connections: planned.map { $0.1 },
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { record in audits.items.withLock { $0.append(record) } },
            log: { _ in })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }

        client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(client.receive()?["result"]?["serverInfo"]?["name"] == .string("rv"))
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = client.receive()?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(tools == ["echo", "whoami"])

        client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}"#)
        #expect(client.receive()?["result"]?["content"]?.arrayValue?.first?["text"] == .string("hello"))

        client.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"whoami"}}"#)
        let whoami = client.receive()
        #expect(whoami?["result"]?["content"]?.arrayValue?.first?["text"] == .string("token is [redacted:FIXTURE_SECRET]"))

        client.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_all"}}"#)
        let denied = client.receive()
        #expect(denied?["result"]?["isError"] == .bool(true))
        #expect(denied?.compactText.contains("deleted everything") == false)

        try client.toGateway.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + 10) == .success)
        let recorded = audits.items.withLock { $0 }
        #expect(recorded.map(\.tool) == ["echo", "whoami", "delete_all"])
        #expect(recorded.map(\.decision) == [.allow, .allow, .deny])
        #expect(recorded.first?.argumentKeys == ["text"])
    }

    @Test func plannerRefusesUnknownBlockedAndUndefinedSecrets() {
        let configuration = MCPConfiguration(
            servers: [MCPServerDefinition(
                name: "a", command: "x", secrets: ["T": "MISSING"], sandbox: MCPSandboxPolicy(network: false))],
            blocked: ["b"])
        let resolver = SecretResolver { _ in .failure(.notFound("x")) }
        func plan(_ name: String) -> MCPLaunchError? {
            if case .failure(let error) = MCPLaunchPlanner.plan(
                servers: [name], configuration: configuration, secrets: SecretsConfiguration(), resolver: resolver,
                baseEnvironment: [:])
            {
                return error
            }
            return nil
        }
        #expect(plan("zzz") == .unknownServer("zzz"))
        #expect(plan("b") == .blocked("b"))
        #expect(plan("a") == .secretUndefined(server: "a", secret: "MISSING"))
    }

    @Test func untrustedConfigurationDoesNotOpenARemoteServer() throws {
        let remote = MCPServerDefinition(
            name: "remote",
            remote: MCPRemoteServer(
                url: try #require(URL(string: "https://a.example/mcp")),
                headers: ["Authorization": "Bearer ${secret:TOKEN}"]))
        var configuration = MCPConfiguration(servers: [remote, MCPServerDefinition(name: "local", command: "echo")])
        configuration.untrusted = true
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "TOKEN", source: .hostEnvironment(variable: "TOKEN"), delivery: .environment),
        ])
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let resolver = SecretResolver { _ in
            calls.count += 1
            return .success(SecretValue("super-secret-token")!)
        }
        var askedForToken = false
        let failed = MCPLaunchPlanner.plan(
            servers: ["remote", "local"], configuration: configuration, secrets: secrets, resolver: resolver,
            baseEnvironment: [:], oauthTokens: { _ in
                askedForToken = true
                return MCPOAuthTokens(
                    accessToken: "at", tokenEndpoint: URL(string: "https://auth.example/token")!, clientID: "c",
                    resource: "https://a.example/mcp")
            })
        guard case .failure(.untrustedRemote("remote")) = failed else {
            Issue.record("untrusted mcp.json planned a remote server")
            return
        }
        #expect(calls.count == 0)
        #expect(askedForToken == false)
        let localSecrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "TOKEN", source: .hostEnvironment(variable: "TOKEN"), delivery: .environment),
        ])
        var localConfiguration = configuration
        localConfiguration.servers = [
            MCPServerDefinition(name: "local", command: "echo", secrets: ["T": "TOKEN"])
        ]
        let local = MCPLaunchPlanner.plan(
            servers: ["local"], configuration: localConfiguration, secrets: localSecrets, resolver: resolver,
            baseEnvironment: [:])
        guard case .failure(.untrustedRemote("local")) = local else {
            Issue.record("untrusted mcp.json planned a local server")
            return
        }
        #expect(calls.count == 0)
    }

    @Test func oauthTokenStaysOnTheResourceURLItWasIssuedFor() throws {
        let issued = MCPOAuthTokens(
            accessToken: "super-token", tokenEndpoint: URL(string: "https://auth.example/token")!, clientID: "c",
            resource: "https://good.example/mcp")
        func plan(_ url: String) throws -> MCPRemoteLaunch? {
            let configuration = MCPConfiguration(servers: [
                MCPServerDefinition(name: "api", remote: MCPRemoteServer(url: try #require(URL(string: url))))
            ])
            let planned = try MCPLaunchPlanner.plan(
                servers: ["api"], configuration: configuration, secrets: SecretsConfiguration(),
                resolver: SecretResolver { _ in .failure(.notFound("x")) }, baseEnvironment: [:],
                oauthTokens: { _ in issued }
            ).get()
            return planned[0].1.remote
        }
        let same = try #require(try plan("https://good.example/mcp"))
        #expect(same.oauth?.accessToken == "super-token")
        for url in [
            "https://evil.example/mcp", "https://good.example/mcp/evil", "https://good.example/api",
            "https://good.example/mcp?x=1", "https://good.example/mcp/", "https://good.example/mcp%2F",
            "https://good.example/%6Dcp",
        ] {
            let moved = try #require(try plan(url))
            #expect(moved.oauth == nil)
            #expect(moved.headers["Authorization"] == nil)
        }
    }
}
