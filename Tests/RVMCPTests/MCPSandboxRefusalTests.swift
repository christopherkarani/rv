import Dispatch
import Foundation
import RVIsolation
import Synchronization
import Testing
@testable import RVMCP

/// Where the host cages servers, a local server whose entry has no
/// `sandbox`, or that asks for open network without listing hosts, is
/// refused on its own: it is never started, its secrets are never
/// resolved, no cage is made for it, and the other servers still serve.
@Suite("MCPSandboxRefusal")
struct MCPSandboxRefusalTests {
    static let secrets = SecretsConfiguration(secrets: [
        SecretDefinition(name: "CAGED_SECRET", source: .hostEnvironment(variable: "CAGED_VAR"), delivery: .environment),
        SecretDefinition(name: "REFUSED_SECRET", source: .hostEnvironment(variable: "REFUSED_VAR"), delivery: .environment),
        SecretDefinition(name: "REFUSED_ARG", source: .hostEnvironment(variable: "REFUSED_ARG_VAR"), delivery: .environment),
    ])

    /// A caged server and `refused`, planned together where the cage is
    /// enforced; the host variables read, and the servers the cage hook saw.
    static func plan(_ refused: MCPServerDefinition) -> (
        result: Result<[(MCPGatewayCore.Upstream, MCPUpstreamConnection)], MCPLaunchError>,
        resolved: [String], caged: [String]
    ) {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "caged", command: "c", secrets: ["TOKEN": "CAGED_SECRET"], sandbox: MCPSandboxPolicy(network: false)),
            refused,
        ])
        let resolved = Mutex<[String]>([])
        let resolver = SecretResolver { source in
            if case .hostEnvironment(let variable) = source { resolved.withLock { $0.append(variable) } }
            return .success(SecretValue("resolved-value")!)
        }
        var caged: [String] = []
        let result = MCPLaunchPlanner.plan(
            servers: ["caged", refused.name], configuration: configuration, secrets: secrets, resolver: resolver,
            baseEnvironment: ["PATH": "/usr/bin:/bin"], requireSandbox: true,
            sandbox: { definition, launch, _ in
                caged.append(definition.name)
                return .success(launch)
            })
        return (result, resolved.withLock { $0 }, caged)
    }

    /// Refused alone with `reason`, before anything was resolved or caged
    /// for it; the caged server is planned to run as before.
    static func expectRefusedAlone(_ refused: MCPServerDefinition, reason: String) {
        let (result, resolved, caged) = plan(refused)
        guard case .success(let planned) = result else {
            Issue.record("\(refused.name) failed the whole plan instead of being refused alone: \(result)")
            return
        }
        #expect(planned.count == 2)
        #expect(planned.first?.1.process?.server == "caged")
        #expect(planned.first?.1.process?.environment["TOKEN"] == "resolved-value")
        guard case .refused(let name, let refusal)? = planned.last?.1 else {
            Issue.record("\(refused.name) was planned to start: \(String(describing: planned.last?.1))")
            return
        }
        #expect(name == refused.name)
        #expect(refusal.message == "sandbox: \(reason)")
        #expect(planned.last?.0.secretValues.isEmpty == true)
        #expect(resolved == ["CAGED_VAR"])
        #expect(caged == ["caged"])
    }

    @Test func aServerWithoutASandboxIsRefusedAloneBeforeItsSecretsAreResolved() {
        Self.expectRefusedAlone(
            MCPServerDefinition(
                name: "bare", command: "b", secrets: ["KEY": "REFUSED_SECRET"]),
            reason: #"bare needs a sandbox; add "sandbox" to its mcp.json entry"#)
    }

    @Test func aServerAskingForOpenNetworkIsRefusedAloneBeforeItsSecretsAreResolved() {
        Self.expectRefusedAlone(
            MCPServerDefinition(
                name: "open", command: "o", secrets: ["KEY": "REFUSED_SECRET"],
                sandbox: MCPSandboxPolicy(network: true)),
            reason: "open stays off the network; list the hosts it needs in sandbox.hosts")
    }

    /// Every server refused: the plan still succeeds and starts nothing,
    /// as when every placeholder server is refused.
    @Test func aPlanOfOnlyRefusedServersStartsNothing() {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b", secrets: ["KEY": "REFUSED_SECRET"])
        ])
        let resolved = Mutex(0)
        let resolver = SecretResolver { _ in
            resolved.withLock { $0 += 1 }
            return .success(SecretValue("resolved-value")!)
        }
        var caged = 0
        let result = MCPLaunchPlanner.plan(
            servers: ["bare"], configuration: configuration, secrets: Self.secrets, resolver: resolver,
            baseEnvironment: [:], requireSandbox: true,
            sandbox: { _, launch, _ in
                caged += 1
                return .success(launch)
            })
        guard case .success(let planned) = result, case .refused("bare", _)? = planned.first?.1 else {
            Issue.record("expected bare to be planned refused: \(result)")
            return
        }
        #expect(planned.count == 1)
        #expect(resolved.withLock { $0 } == 0)
        #expect(caged == 0)
    }

    /// Through the real runtime: the refused server is never spawned (its
    /// command would create `marker`), serve says why on its log, the
    /// caged server's tools are listed and called, and a call to the
    /// refused server is answered by rv and audited as not run.
    @Test(.enabled(if: python3Available)) func theOtherServersServeWhileTheRefusedOneNeverStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        try Data(fixtureServer.utf8).write(to: script)
        let marker = directory.appendingPathComponent("bare-started")

        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "fixture", command: "python3", args: ["-u", script.path],
                tools: MCPToolPolicy(allow: ["*"], deny: ["delete_*"]),
                sandbox: MCPSandboxPolicy(network: false)),
            MCPServerDefinition(
                name: "bare", command: "touch", args: [marker.path], tools: MCPToolPolicy(allow: ["*"])),
        ])
        var base = ProcessInfo.processInfo.environment
        base["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:" + (base["PATH"] ?? "")
        let planned = try MCPLaunchPlanner.plan(
            servers: ["fixture", "bare"], configuration: configuration, secrets: SecretsConfiguration(),
            resolver: SecretResolver { _ in .failure(.notFound("none")) }, baseEnvironment: base, requireSandbox: true,
            sandbox: { _, launch, _ in .success(launch) }
        ).get()

        let client = LineClient()
        let audits = RecordedAudits()
        let logs = Mutex<[String]>([])
        let core = MCPGatewayCore(
            configuration: configuration, upstreams: planned.map { $0.0 },
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        let runtime = MCPGatewayRuntime(
            core: core, connections: planned.map { $0.1 },
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { record in audits.items.withLock { $0.append(record) } },
            log: { line in logs.withLock { $0.append(line) } })
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
        // Two servers in mcp.json: tools are listed under `<server>__`.
        #expect(tools == ["fixture__echo", "fixture__whoami"])

        client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fixture__echo","arguments":{"text":"hello"}}}"#)
        #expect(client.receive()?["result"]?["content"]?.arrayValue?.first?["text"] == .string("hello"))

        client.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"bare__echo","arguments":{"text":"hi"}}}"#)
        let refused = client.receive()
        let message = refused?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("MCP server bare is unavailable"), "\(String(describing: refused))")

        try client.toGateway.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        let bare = audits.items.withLock { $0 }.filter { $0.server == "bare" }
        #expect(bare.count == 1)
        #expect(bare.allSatisfy { $0.isError && $0.outcome == .notRun })
        let logged = logs.withLock { $0 }
        #expect(
            logged.contains(#"not starting MCP server bare: sandbox: bare needs a sandbox; add "sandbox" to its mcp.json entry"#),
            "\(logged)")
    }
}
