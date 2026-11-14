import Foundation
import RVIsolation
import RVMCP
import RVPolicy
import Synchronization
import Testing
@testable import RVCLI

/// `rv mcp` where rv's key is a file any same-user process can read
/// (Linux): trust, serve and approve refuse with the platform wording.
@Suite("rv mcp platform support")
struct MCPPlatformSupportCommandTests {
    typealias Fixture = MCPCommandTests.Fixture

    static func sameUser(_ fixture: Fixture) -> MCPApprovalSigning {
        .file(configDirectory: fixture.config, honorsGrants: false)
    }

    static func write(_ fixture: Fixture) throws {
        _ = try MCPConfiguration(servers: [
            MCPServerDefinition(name: "fs", command: "fs-mcp", sandbox: MCPSandboxPolicy(network: false))
        ]).write(configDirectory: fixture.config, signing: sameUser(fixture)).get()
    }

    @Test func trustRefusesBeforeAskingForPresence() async throws {
        let fixture = Fixture()
        try Self.write(fixture)
        let asked = Mutex(false)
        let presence = UserPresence { _, _ in
            asked.withLock { $0 = true }
            return .confirmed(method: "test")
        }
        let shown = Mutex("")
        let result = await MCPRun.trust(
            environment: fixture.environment(presence: presence, approvalSigning: Self.sameUser(fixture)),
            show: { text in shown.withLock { $0 += text } })
        #expect(result.failureMessage == MCPPlatformSupport.trustUnavailable)
        #expect(asked.withLock { $0 } == false)
        #expect(shown.withLock { $0 }.isEmpty)
    }

    /// Same-user custody never records a request, so without the platform
    /// wording approve would answer "no pending approval" and send the
    /// person hunting for an id that cannot exist.
    @Test func approveSaysApprovalsAreUnavailableHere() async throws {
        let fixture = Fixture()
        try Self.write(fixture)
        let environment = fixture.environment(approvalSigning: Self.sameUser(fixture))
        #expect(environment.approvals.request(server: "fs", tool: "read", argumentsHash: "h", argumentKeys: []) == nil)
        for always in [false, true] {
            let result = await MCPRun.approve(id: "any", always: always, environment: environment)
            #expect(result.failureMessage == MCPPlatformSupport.approvalsUnavailable)
        }
        #expect(MCPPlatformSupport.approvalsUnavailable.contains("unavailable without a key custodian this agent cannot read"))
        #expect(MCPPlatformSupport.approvalsUnavailable.contains("macOS"))
    }

    @Test func serveLaunchesNothingAndSaysWhy() throws {
        let fixture = Fixture()
        try Self.write(fixture)
        let environment = fixture.environment(approvalSigning: Self.sameUser(fixture))
        let configuration = try MCPRun.configuration(environment).get()
        let refused = MCPRun.upstreamLaunches(
            names: ["fs"], configuration: configuration, environment: environment, secrets: SecretsConfiguration(),
            resolver: SecretResolver { _ in .failure(.notFound("none")) })
        #expect(refused.failureMessage?.contains("MCP gateway trust is unavailable without a key custodian") == true)
        #expect(refused.failureMessage?.hasSuffix("not launching MCP servers") == true)
    }

    @Test func checkReportsTheIntegrityAsUnsupported() throws {
        let fixture = Fixture()
        try Self.write(fixture)
        let environment = fixture.environment(approvalSigning: Self.sameUser(fixture))
        let configuration = try MCPRun.configuration(environment).get()
        let report = MCPRun.report(environment, project: nil, configuration: configuration, rvExecutable: "")
        #expect(report.integrity == "unsupported")
        #expect(report.integrityProblem == MCPPlatformSupport.trustUnavailable)
        #expect(report.passes == false)
    }

    /// Without a cage `rv mcp check` names every local server: refused
    /// when it asks for a sandbox or the organization requires one, and
    /// uncaged otherwise.
    @Test func checkSaysWhichServersRunUncagedOrAreRefused() throws {
        var configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b"),
            MCPServerDefinition(name: "closed", command: "c", sandbox: MCPSandboxPolicy(network: false)),
            MCPServerDefinition(
                name: "remote", remote: MCPRemoteServer(url: try #require(URL(string: "https://mcp.example.com/mcp")))),
        ])
        let directory = URL(fileURLWithPath: "/nonexistent")
        let uncaged = MCPRun.sandboxProblems(configuration, configDirectory: directory, requireSandbox: false)
        #expect(uncaged.map(\.message) == [
            MCPPlatformSupport.runsUncaged(server: "bare"),
            MCPPlatformSupport.sandboxUnenforced(server: "closed"),
        ])

        configuration.managed = try ManagedPolicy.decode(Data(#"{"version":1,"mcp":{"requireSandbox":true}}"#.utf8)).get()
        let required = MCPRun.sandboxProblems(configuration, configDirectory: directory, requireSandbox: false)
        #expect(required.map(\.message) == [
            MCPPlatformSupport.organizationSandboxUnenforced(server: "bare"),
            MCPPlatformSupport.organizationSandboxUnenforced(server: "closed"),
        ])
    }

    @Test func managedStatusSaysTheSandboxRequirementRefusesEveryLocalServerWithoutACage() throws {
        let required = try ManagedPolicy.decode(Data(#"{"version":1,"mcp":{"requireSandbox":true}}"#.utf8)).get()
        let plain = try ManagedPolicy.decode(Data(#"{"version":1}"#.utf8)).get()
        let caged = "mcp: every local server must be sandboxed (remote servers are exempt)"
        #expect(ManagedRun.restrictions(required, sandboxEnforced: true) == [caged])
        #expect(ManagedRun.restrictions(plain, sandboxEnforced: true) == [caged])
        #expect(ManagedRun.restrictions(required, sandboxEnforced: false) == [
            "mcp: no MCP server sandbox on this host, so every local server is refused here (remote servers are exempt)"
        ])
        #expect(ManagedRun.restrictions(plain, sandboxEnforced: false) == [
            "mcp: sandboxes need macOS; sandboxed servers are refused here (remote servers are exempt)"
        ])
    }
}
