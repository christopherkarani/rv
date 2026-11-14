import Foundation
import RVIsolation
import RVPolicy
import Testing
@testable import RVMCP

/// What the gateway refuses where rv cannot protect its key from other
/// processes running as the user or cannot cage a server (Linux today).
/// The capability is a value, so these run on any host.
@Suite("MCP platform support")
struct MCPPlatformSupportTests {
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-platform-\(UUID().uuidString)")
    }

    static let configuration = MCPConfiguration(servers: [
        MCPServerDefinition(name: "gh", command: "gh-mcp", tools: MCPToolPolicy(allow: ["list_*"]))
    ])

    /// Linux's key file: any same-user process can read it and sign an
    /// edited mcp.json, so no signature made with it is trusted.
    @Test func sameUserKeyCustodyNeverTrustsMCPJSON() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sameUser = MCPApprovalSigning.file(configDirectory: directory, honorsGrants: false)
        #expect(MCPIntegrity.status(configDirectory: directory, signing: sameUser) == .noConfiguration)

        _ = try Self.configuration.write(configDirectory: directory, signing: sameUser).get()
        #expect(MCPIntegrity.signCurrent(configDirectory: directory, signing: sameUser))
        let status = MCPIntegrity.status(configDirectory: directory, signing: sameUser)
        #expect(status == .unsupportedPlatform)
        #expect(status.isTrusted == false)
        #expect(status.label == "unsupported")
        #expect(status.problem == MCPPlatformSupport.trustUnavailable)
        #expect(status.problem?.contains("unavailable without a key custodian this agent cannot read") == true)
        #expect(status.problem?.contains("rv mcp trust") == false)

        // The same file under a key that resists same-user processes is trusted.
        #expect(MCPIntegrity.status(configDirectory: directory, signing: .file(configDirectory: directory)) == .trusted)
    }

    /// An unreachable custodian (macOS) is not a platform limit: it keeps
    /// its own "no key" wording.
    @Test func unreachableCustodianIsNotReportedAsAPlatformLimit() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try Self.configuration.write(configDirectory: directory, signing: .file(configDirectory: directory)).get()
        #expect(MCPApprovalSigning.unavailable.custodyIsSameUser == false)
        #expect(MCPApprovalSigning.file(configDirectory: directory).custodyIsSameUser == false)
        #expect(MCPApprovalSigning.file(configDirectory: directory, honorsGrants: false).custodyIsSameUser)
        #expect(MCPIntegrity.status(configDirectory: directory, signing: .unavailable)
            == .untrusted("rv has no approvals key to check it with"))
    }

    static func plan(
        _ name: String, configuration: MCPConfiguration, cage: Bool
    ) -> Result<[(MCPGatewayCore.Upstream, MCPUpstreamConnection)], MCPLaunchError> {
        MCPLaunchPlanner.plan(
            servers: [name], configuration: configuration, secrets: SecretsConfiguration(),
            resolver: SecretResolver { _ in .failure(.notFound("none")) }, baseEnvironment: [:],
            requireSandbox: cage)
    }

    /// `requireSandbox` from the organization is a promise every local
    /// server runs caged. Without a cage the planner refuses each one
    /// instead of starting it bare; remote servers have no local process.
    @Test func organizationSandboxRequirementRefusesEveryLocalServerWithoutACage() throws {
        var configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b"),
            MCPServerDefinition(name: "closed", command: "c", sandbox: MCPSandboxPolicy(network: false)),
            MCPServerDefinition(
                name: "remote", remote: MCPRemoteServer(url: try #require(URL(string: "https://mcp.example.com/mcp")))),
        ])
        configuration.managed = try ManagedPolicy.decode(Data(#"{"version":1,"mcp":{"requireSandbox":true}}"#.utf8)).get()
        for name in ["bare", "closed"] {
            guard case .failure(.sandbox(let reason)) = Self.plan(name, configuration: configuration, cage: false) else {
                Issue.record("\(name) launched without the sandbox organization policy requires")
                continue
            }
            #expect(reason == MCPPlatformSupport.organizationSandboxUnenforced(server: name))
        }
        if case .failure(let error) = Self.plan("remote", configuration: configuration, cage: false) {
            Issue.record("remote server refused: \(error.message)")
        }

        configuration.managed?.mcp.requireSandbox = false
        if case .failure(let error) = Self.plan("bare", configuration: configuration, cage: false) {
            Issue.record("bare server refused without the organization flag: \(error.message)")
        }
        // Where the cage runs, the flag changes nothing: `closed` plans.
        configuration.managed?.mcp.requireSandbox = true
        if case .failure(let error) = Self.plan("closed", configuration: configuration, cage: true) {
            Issue.record("caged server refused: \(error.message)")
        }
    }

    /// Serve's sandbox hook never runs a server that asks for a cage it
    /// cannot build; a bare server passes through unchanged.
    @Test func sandboxHookRefusesASandboxItCannotEnforce() {
        let directory = Self.scratch()
        let apply = MCPSandbox.apply(configDirectory: directory, home: directory, enforced: false)
        let launch = MCPUpstreamLaunch(server: "x", executable: "/usr/bin/env", arguments: ["x"], environment: [:])
        let caged = MCPServerDefinition(name: "closed", command: "c", sandbox: MCPSandboxPolicy(network: false))
        #expect(apply(caged, launch) == .failure(.sandbox(MCPPlatformSupport.sandboxUnenforced(server: "closed"))))
        #expect(apply(MCPServerDefinition(name: "bare", command: "b"), launch) == .success(launch))
    }

    @Test func sandboxWordingNamesThePlatform() {
        #expect(MCPPlatformSupport.sandboxUnenforced(server: "a").contains("sandbox is unavailable on this host"))
        #expect(MCPPlatformSupport.organizationSandboxUnenforced(server: "a").contains("sandbox is unavailable on this host"))
        #expect(MCPPlatformSupport.runsUncaged(server: "a").contains("runs it uncaged"))
        #expect(MCPPlatformSupport.runsUncaged(server: "a").contains("sandbox is unavailable on this host"))
    }
}
