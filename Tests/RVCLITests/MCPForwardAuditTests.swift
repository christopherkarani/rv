import Foundation
import RVHistory
@testable import RVMCP
import Testing
@testable import RVCLI

/// `rv mcp serve` writes each call's audit record before forwarding it, and
/// reports a write it could not make so the gateway refuses the call.
@Suite("rv mcp serve forward audit")
struct MCPForwardAuditTests {
    static let record = MCPCallRecord(
        server: "github", tool: "search", decision: .allow, argumentKeys: ["q"], isError: false,
        outcome: .forwarding(grant: nil))

    @Test func theForwardRecordIsAppendedBeforeTheCallRuns() {
        let fixture = MCPCommandTests.Fixture()
        #expect(MCPRun.recordForward(Self.record, configDirectory: fixture.config))
        let events = AuditLedger(configDirectory: fixture.config).events(AuditFilter(kinds: [AuditEventKind.mcpCall.rawValue]))
        #expect(events.count == 1)
        #expect(events.first?.subject == "github/search")
        #expect(events.first?.decision == .allowed)
        #expect(events.first?.detail["stage"] == "forward")
    }

    static let configuration = MCPConfiguration(servers: [
        MCPServerDefinition(name: "github", command: "gh-mcp", tools: MCPToolPolicy(allow: ["search"]))
    ])

    static func serveCore(_ environment: MCPEnvironment) -> MCPGatewayCore {
        MCPRun.serveCore(
            configuration: configuration, upstreams: [MCPGatewayCore.Upstream(definition: configuration.servers[0])],
            environment: environment, pinning: .unenforced)
    }

    static func forwardSearch(_ core: inout MCPGatewayCore) -> [MCPGatewayOutput] {
        var params = RVMCP.JSONObject()
        params["name"] = .string("search")
        params["arguments"] = .object(["q": .string("rv")])
        return core.forward(client: .int(7), server: "github", tool: "search", keys: ["q"], approval: nil, params: params)
    }

    /// M4: the gateway `rv mcp serve` builds writes its forward record to
    /// this environment's audit log before the call goes upstream.
    @Test func serveWritesTheForwardRecordToItsAuditLog() {
        let fixture = MCPCommandTests.Fixture()
        var core = Self.serveCore(fixture.environment())
        let outputs = Self.forwardSearch(&core)
        #expect(outputs.contains { if case .toUpstream(let server, _) = $0 { server == "github" } else { false } })
        let events = AuditLedger(configDirectory: fixture.config).events(AuditFilter(kinds: [AuditEventKind.mcpCall.rawValue]))
        #expect(events.map(\.subject) == ["github/search"])
        #expect(events.first?.detail["stage"] == "forward")
        #expect(events.first?.detail["argumentKeys"] == "q")
    }

    /// Where serve's audit log cannot be written, the call is refused and
    /// nothing goes upstream.
    @Test func serveRefusesACallItCannotAudit() throws {
        let fixture = MCPCommandTests.Fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let config = blocker.appendingPathComponent("rv")
        let environment = MCPEnvironment(
            configDirectory: config, home: fixture.home, processEnvironment: [:], keychain: fixture.keychain.writer,
            approvalSigning: .file(configDirectory: config), presence: MCPCommandTests.present,
            oauthTokens: .file(configDirectory: config))
        var core = Self.serveCore(environment)
        let outputs = Self.forwardSearch(&core)
        #expect(outputs.contains { if case .toUpstream = $0 { true } else { false } } == false)
        let reply = outputs.compactMap { if case .toClient(let message) = $0 { message } else { nil } }.first
        #expect(reply?["error"]?["code"] == .int(-32603))
    }

    @Test func anAuditLogThatCannotBeWrittenReportsFailure() throws {
        let fixture = MCPCommandTests.Fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        #expect(MCPRun.recordForward(Self.record, configDirectory: blocker.appendingPathComponent("rv")) == false)
    }
}
